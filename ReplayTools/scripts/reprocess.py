#!/usr/bin/env python3
"""Bring a Wobble recording up to the app's current algorithms.

  * stroke_rate_spm  -> recomputed with the app's fused detector (dominant rhythm
                        of pitch, gravity z and GPS speed; ReplayTools
                        `FusedAnalyzer`, run via the Swift CLI so it is the same
                        code as the replay harness).
  * surge_g          -> recomputed from the logged orientation + user acceleration
                        (the fused detector uses it only for its idle gate).
  * wobble_roll_deg, roll_rate_deg_s -> added if missing (see add_roll_wobble.py).

Surge is always recomputed, never taken from the file: until October 2026 the app
rotated acceleration into the world frame with CMRotationMatrix itself (world ->
device) instead of its transpose, so logged surge_g mixed in vertical motion. The
projection matches the app's (GPS course, else the principal axis of recent
horizontal acceleration, else the last axis). Recordings from before the app used
a true-north reference (June 2026 and earlier) have an arbitrary yaw, so their
surge is not truly fore-aft either way.

Works on an app CSV (-> <name>_reprocessed.csv) or a combined Excel workbook
(-> <name>_reprocessed.xlsx; charts, pivot tables, sorts and filters are kept and
pivot caches refresh on open). The input is never modified.

Usage:
    python3 reprocess.py <recording.csv | combined.xlsx> [--out <path>]
"""

import csv
import math
import re
import subprocess
import sys
import tempfile
import zipfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import add_roll_wobble as roll  # noqa: E402

PACKAGE = Path(__file__).resolve().parent.parent
MIN_COURSE_SPEED = 0.5   # DataRecorder.minCourseSpeed
AXIS_BUFFER = 100        # DataRecorder.axisBufferSize
PCA_MIN_SAMPLES = 20     # DataRecorder.pcaMinSamples
MIN_SURGE_VARIANCE = 0.0025
SURGE_COLS = ["pitch_rad", "roll_rad", "yaw_rad", "user_accel_x_g", "user_accel_y_g",
              "user_accel_z_g", "speed_mps", "course_deg"]


# MARK: - Surge (as the app computes it)

def rebuild_surge(rows):
    """rows: dicts for one session in stopwatch order -> surge_g per row."""
    buf, last, out = [], None, []
    for r in rows:
        # Same device -> world rotation the wobble roll columns use
        wx, wy = roll.world_rotation(r["pitch_rad"], r["roll_rad"], r["yaw_rad"],
                                     r["user_accel_x_g"], r["user_accel_y_g"], r["user_accel_z_g"])
        buf.append((wx, wy))
        if len(buf) > AXIS_BUFFER:
            buf.pop(0)
        axis = None
        if r["course_deg"] >= 0 and r["speed_mps"] > MIN_COURSE_SPEED:
            rad = math.radians(r["course_deg"])
            axis = (math.cos(rad), -math.sin(rad))
        elif len(buf) >= PCA_MIN_SAMPLES:
            n = len(buf)
            mx = sum(p[0] for p in buf) / n
            my = sum(p[1] for p in buf) / n
            sxx = sum((p[0] - mx) ** 2 for p in buf)
            syy = sum((p[1] - my) ** 2 for p in buf)
            sxy = sum((p[0] - mx) * (p[1] - my) for p in buf)
            if (sxx + syy) / n > MIN_SURGE_VARIANCE:
                th = 0.5 * math.atan2(2 * sxy, sxx - syy)
                axis = (math.cos(th), math.sin(th))
                if last and axis[0] * last[0] + axis[1] * last[1] < 0:
                    axis = (-axis[0], -axis[1])
        if axis is None:
            axis = last
        if axis:
            last = axis
        out.append(wx * axis[0] + wy * axis[1] if axis else 0.0)
    return out


# MARK: - Stroke rate (Swift FusedAnalyzer)

def replay_binary():
    subprocess.run(["swift", "build", "-q", "--package-path", str(PACKAGE)], check=True)
    out = subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "--show-bin-path"],
                         check=True, capture_output=True, text=True).stdout.strip()
    return Path(out) / "wobble-replay"


def fused_rates(binary, data, surges, tmp):
    src, dst = Path(tmp) / "in.csv", Path(tmp) / "out.csv"
    with open(src, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["stopwatch_time_s", "surge_g", "pitch_rad", "gravity_z_g", "speed_mps"])
        w.writerows((d["stopwatch_time_s"], s, d["pitch_rad"], d["gravity_z_g"], d["speed_mps"])
                    for d, s in zip(data, surges))
    subprocess.run([str(binary), str(src), "--method", "fused", "--out", str(dst)],
                   check=True, capture_output=True)
    with open(dst, newline="") as f:
        return [float(r["stroke_rate_new_spm"]) for r in csv.DictReader(f)]


# MARK: - Processing

def compute(header, rows):
    """Returns (stroke rates per row, surge per row, {roll column: values} for roll
    columns not yet present)."""
    ix = {name: i for i, name in enumerate(header)}
    missing = [c for c in SURGE_COLS + ["gravity_z_g", "stopwatch_time_s", "stroke_rate_spm"] if c not in ix]
    if missing:
        sys.exit(f"error: missing columns: {', '.join(missing)}")
    key_cols = ["source_file"] if "source_file" in ix else [c for c in ("user_uuid", "track") if c in ix]

    sessions = defaultdict(list)
    for i, row in enumerate(rows):
        try:
            parsed = {c: float(row[ix[c]]) for c in SURGE_COLS + ["gravity_z_g", "stopwatch_time_s"]}
        except (TypeError, ValueError, IndexError):
            continue
        sessions[tuple(row[ix[c]] for c in key_cols)].append((i, parsed))

    binary = replay_binary()
    rates = [None] * len(rows)
    surge = [None] * len(rows)
    with tempfile.TemporaryDirectory() as tmp:
        for members in sessions.values():
            members.sort(key=lambda m: m[1]["stopwatch_time_s"])
            data = [m[1] for m in members]
            surges = rebuild_surge(data)
            for (i, _), s, rate in zip(members, surges, fused_rates(binary, data, surges, tmp)):
                surge[i] = round(s, 6)  # app logs surge at %.6f
                rates[i] = rate

    print(f"{len(sessions)} session(s); surge recomputed for all", file=sys.stderr)
    return rates, surge, roll.compute(header, rows)


def process_csv(src, dst):
    with open(src, newline="") as f:
        data = list(csv.reader(f))
    header, rows = data[0], data[1:]
    rates, surge, roll_values = compute(header, rows)
    if "surge_g" not in header:
        header = header + ["surge_g"]
    sr, sg = header.index("stroke_rate_spm"), header.index("surge_g")
    with open(dst, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header + list(roll_values))
        for i, row in enumerate(rows):
            row = list(row) + [""] * (len(header) - len(row))
            if rates[i] is not None:
                row[sr] = rates[i]
                row[sg] = surge[i]
            w.writerow(row + ["" if roll_values[c][i] is None else roll_values[c][i] for c in roll_values])


def process_xlsx(src, dst):
    z = zipfile.ZipFile(src)
    name, path, cells = roll.find_data_sheet(z)
    header_row, header, data_rows, rows = roll.table(cells)
    rates, surge, roll_values = compute(header, rows)
    if "surge_g" not in header:
        sys.exit("error: workbook has no surge_g column to update")
    updates = [(roll.col_letter(header.index(c) + 1), dict(zip(data_rows, v)))
               for c, v in (("stroke_rate_spm", rates), ("surge_g", surge))]
    sr_l = updates[0][0]

    def set_cell(r, body, letter, value):
        cell = f'<c r="{letter}{r}"><v>{value}</v></c>'
        body, n = re.subn(rf'<c r="{letter}{r}"(?:[^>]*?/>|[^>]*>.*?</c>)', cell, body, count=1, flags=re.S)
        if n == 0:  # no existing cell: insert it in column order
            if body.endswith("/>"):
                return body[:-2].rstrip() + ">" + cell + "</row>"
            after = [c for c in re.finditer(r'<c r="([A-Z]+)\d+"', body)
                     if roll.col_number(c.group(1)) > roll.col_number(letter)]
            at = after[0].start() if after else len(body) - len("</row>")
            body = body[:at] + cell + body[at:]
        return body

    def set_values(r, body):
        for letter, by_row in updates:
            value = by_row.get(r)
            if value is not None:
                body = set_cell(r, body, letter, value)
        return body

    parts = {}
    new_cols = [(c, dict(zip(data_rows, v))) for c, v in roll_values.items()]
    xml = roll.append_columns(z.read(path).decode("utf-8"), name, header_row, len(header),
                              new_cols, z, parts, row_values=set_values)
    parts[path] = xml.encode("utf-8")
    # Values changed: make pivots built on this sheet refresh on open.
    for part in z.namelist():
        if part.startswith("xl/pivotCache/pivotCacheDefinition") and part.endswith(".xml"):
            pc = (parts[part] if part in parts else z.read(part)).decode("utf-8")
            if f'sheet="{name}"' in pc and "refreshOnLoad" not in pc:
                parts[part] = pc.replace("<pivotCacheDefinition ", '<pivotCacheDefinition refreshOnLoad="1" ', 1).encode("utf-8")
    roll.write_zip(z, dst, parts)
    print(f"sheet '{name}': stroke_rate_spm (column {sr_l}) and surge_g (column {updates[1][0]}) recomputed"
          + (f"; added {', '.join(roll_values)}" if roll_values else ""), file=sys.stderr)


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__.strip().split("Usage:")[1].strip())
    src = Path(args[0])
    dst = Path(args[args.index("--out") + 1]) if "--out" in args else src.with_name(f"{src.stem}_reprocessed{src.suffix}")
    if dst.resolve() == src.resolve():
        sys.exit("error: output would overwrite the input")
    if src.suffix.lower() == ".csv":
        process_csv(src, dst)
    elif src.suffix.lower() == ".xlsx":
        process_xlsx(src, dst)
    else:
        sys.exit("error: input must be .csv or .xlsx")
    print(f"wrote {dst}", file=sys.stderr)


if __name__ == "__main__":
    main()
