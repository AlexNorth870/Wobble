#!/usr/bin/env python3
"""Add roll-only wobble columns to a Wobble recording.

  * wobble_roll_deg  - the app's roll-only wobble factor: |roll rate| averaged over
                       a rolling (trailing) 10 s window, deg/s.
  * roll_rate_deg_s  - the instantaneous roll rate, no averaging, deg/s, signed:
                       positive = rolling toward starboard (port side rising),
                       negative = toward port. Blank until the session's first GPS
                       course, since the roll axis needs a direction of travel.

Roll rate is the rotation rate rotated into the world frame and projected onto the
GPS travel direction (side-to-side roll only; pitch from the stroke and yaw from
steering are excluded), as in DataRecorder.recordDataPoint. Until GPS gives a
course, the averaged column uses all horizontal rotation (still excludes yaw).

Only columns not already present are added. Works on:
  * a CSV straight from the app             -> writes <name>_roll.csv
  * an Excel workbook of combined recordings -> writes <name>_roll.xlsx

Rows may be in any order (e.g. a sorted or filtered sheet): each session is
computed in stopwatch order and every value is written back to its own row,
including rows hidden by a filter. Sessions are keyed by `source_file` when
present, otherwise by `user_uuid` + `track`.

For .xlsx the columns are spliced into the sheet XML directly so charts, pivot
tables, sorts, filters and hidden rows survive (re-saving with openpyxl would drop
charts). A pivot cache built on the sheet is widened to the new columns and set to
refresh when the workbook is opened. Standard library only; no installs needed.

Usage:
    python3 add_roll_wobble.py <recording.csv | combined.xlsx> [--out <path>]
"""

import csv
import math
import re
import sys
import zipfile
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

AVERAGE_COLUMN = "wobble_roll_deg"
INSTANT_COLUMN = "roll_rate_deg_s"
COLUMNS = [AVERAGE_COLUMN, INSTANT_COLUMN]
WINDOW = 100            # 10 s at the app's 0.1 s sample interval
MIN_COURSE_SPEED = 0.5  # m/s; matches DataRecorder.minCourseSpeed
REQUIRED = ["stopwatch_time_s", "speed_mps", "course_deg", "pitch_rad", "roll_rad",
            "yaw_rad", "rotation_rate_x_rads", "rotation_rate_y_rads", "rotation_rate_z_rads"]

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
# A <row>: self-closing (empty) or with content. Group 1 = row number.
ROW_RE = re.compile(r'<row r="(\d+)"(?:[^>]*?/>|[^>]*>.*?</row>)', re.S)


# MARK: - Algorithm

def world_rotation(pitch, roll, yaw, wx, wy, wz):
    """Rotate a device-frame vector into the world frame (X = true north, Y = west,
    Z = up). R = Rz(yaw)·Rx(pitch)·Ry(roll) is CoreMotion's device->world rotation
    (the transpose of CMRotationMatrix); only the horizontal part is needed."""
    cp, sp = math.cos(pitch), math.sin(pitch)
    cr, sr = math.cos(roll), math.sin(roll)
    cy, sy = math.cos(yaw), math.sin(yaw)
    # Rx(pitch)·Ry(roll) applied to w
    x1 = cr * wx + sr * wz
    y1 = sp * sr * wx + cp * wy - sp * cr * wz
    # Rz(yaw)
    return cy * x1 - sy * y1, sy * x1 + cy * y1


def roll_series(rows):
    """rows: dicts for ONE session in stopwatch order.
    Returns {column: [value or None per row]} for both roll columns."""
    buf, axis = [], None
    average, instant = [], []
    for r in rows:
        wx, wy = world_rotation(r["pitch_rad"], r["roll_rad"], r["yaw_rad"],
                                r["rotation_rate_x_rads"], r["rotation_rate_y_rads"],
                                r["rotation_rate_z_rads"])
        if r["course_deg"] >= 0 and r["speed_mps"] > MIN_COURSE_SPEED:
            rad = math.radians(r["course_deg"])
            axis = (math.cos(rad), -math.sin(rad))
        if axis:
            # Right-hand rotation about the travel direction lifts the port side.
            signed = wx * axis[0] + wy * axis[1]
            rate = abs(signed)
            instant.append(round(math.degrees(signed), 4))
        else:
            rate = math.hypot(wx, wy)
            instant.append(None)
        buf.append(rate)
        if len(buf) > WINDOW:
            buf.pop(0)
        average.append(round(math.degrees(sum(buf) / len(buf)), 4))
    return {AVERAGE_COLUMN: average, INSTANT_COLUMN: instant}


def compute(header, rows):
    """header: column names; rows: lists of raw values.
    Returns {column: [value or None per row]} for the roll columns not yet in header."""
    missing = [c for c in REQUIRED if c not in header]
    if missing:
        sys.exit(f"error: missing columns: {', '.join(missing)}")
    wanted = [c for c in COLUMNS if c not in header]
    if not wanted:
        return {}
    ix = {name: i for i, name in enumerate(header)}
    key_cols = ["source_file"] if "source_file" in ix else [c for c in ("user_uuid", "track") if c in ix]

    sessions = defaultdict(list)
    for i, row in enumerate(rows):
        try:
            parsed = {c: float(row[ix[c]]) for c in REQUIRED}
        except (TypeError, ValueError, IndexError):
            continue  # blank or non-numeric row
        sessions[tuple(row[ix[c]] for c in key_cols)].append((i, parsed))

    values = {c: [None] * len(rows) for c in wanted}
    for members in sessions.values():
        members.sort(key=lambda m: m[1]["stopwatch_time_s"])
        series = roll_series([m[1] for m in members])
        for c in wanted:
            for (i, _), v in zip(members, series[c]):
                values[c][i] = v
    print(f"{len(sessions)} session(s); adding {', '.join(wanted)}", file=sys.stderr)
    return values


# MARK: - CSV

def process_csv(src, dst):
    with open(src, newline="") as f:
        data = list(csv.reader(f))
    header, rows = data[0], data[1:]
    values = compute(header, rows)
    if not values:
        sys.exit("nothing to do: roll columns already present")
    with open(dst, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header + list(values))
        for i, row in enumerate(rows):
            w.writerow(row + ["" if values[c][i] is None else values[c][i] for c in values])


# MARK: - XLSX

def col_letter(n):  # 1-based
    s = ""
    while n:
        n, rem = divmod(n - 1, 26)
        s = chr(65 + rem) + s
    return s


def col_number(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def read_shared_strings(z):
    if "xl/sharedStrings.xml" not in z.namelist():
        return []
    return ["".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t"))
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS)]


def read_sheets(z):
    """Map sheet name -> part path for worksheets in the workbook."""
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    targets = {r.get("Id"): r.get("Target") for r in rels}
    sheets = {}
    for s in wb.find("m:sheets", NS):
        target = targets[s.get(f"{{{REL_NS}}}id")].lstrip("/")
        path = target if target.startswith("xl/") else "xl/" + target
        if "/worksheets/" in path:
            sheets[s.get("name")] = path
    return sheets


def read_cells(xml_bytes, shared):
    """Return {row_number: {column_number: value}} for a worksheet part."""
    rows = {}
    for row in ET.fromstring(xml_bytes).iter(f"{{{NS['m']}}}row"):
        cells = {}
        for c in row.findall("m:c", NS):
            col = col_number(re.match(r"[A-Z]+", c.get("r")).group(0))
            t, v = c.get("t"), c.find("m:v", NS)
            if t == "s" and v is not None:
                cells[col] = shared[int(v.text)]
            elif t == "inlineStr":
                cells[col] = "".join(x.text or "" for x in c.iter(f"{{{NS['m']}}}t"))
            elif v is not None:
                cells[col] = v.text
        rows[int(row.get("r"))] = cells
    return rows


def find_data_sheet(z):
    """(sheet name, part path, cells) for the sheet holding the recording columns."""
    shared = read_shared_strings(z)
    for name, path in read_sheets(z).items():
        cells = read_cells(z.read(path), shared)
        if cells and "rotation_rate_x_rads" in cells[min(cells)].values():
            return name, path, cells
    sys.exit("error: no sheet with Wobble recording columns found")


def table(cells):
    """(header row number, header names, data row numbers, data rows as lists)."""
    header_row = min(cells)
    last_col = max(cells[header_row])
    header = [cells[header_row].get(c) for c in range(1, last_col + 1)]
    data_rows = sorted(r for r in cells if r > header_row)
    rows = [[cells[r].get(c) for c in range(1, last_col + 1)] for r in data_rows]
    return header_row, header, data_rows, rows


def append_columns(sheet_xml, name, header_row, last_col, new_cols, z, parts, row_values=None):
    """Append columns after `last_col` in the sheet XML. new_cols: [(header, {row: value})].
    Widens the used range, autofilter/sort ranges and pivot caches on this sheet.
    `row_values`, if given, is applied to each row's XML first: f(row_number, row_xml) -> row_xml."""
    letters = [col_letter(last_col + 1 + k) for k in range(len(new_cols))]

    def fix_row(m):
        r, body = int(m.group(1)), m.group(0)
        if row_values:
            body = row_values(r, body)
        if not new_cols:
            return body
        added = []
        for (title, vals), letter in zip(new_cols, letters):
            if r == header_row:
                added.append(f'<c r="{letter}{r}" t="inlineStr"><is><t>{title}</t></is></c>')
            elif vals.get(r) is not None:
                added.append(f'<c r="{letter}{r}"><v>{vals[r]}</v></c>')
        if not added:
            return body
        if body.endswith("/>"):  # empty self-closing row
            return body[:-2].rstrip() + ">" + "".join(added) + "</row>"
        return body[: -len("</row>")] + "".join(added) + "</row>"

    sheet_xml = ROW_RE.sub(fix_row, sheet_xml)
    if not new_cols:
        return sheet_xml
    old_l, new_l, new_last = col_letter(last_col), letters[-1], last_col + len(new_cols)
    sheet_xml = re.sub(r'spans="(\d+):(\d+)"',
                       lambda m: f'spans="{m.group(1)}:{max(int(m.group(2)), new_last)}"', sheet_xml)
    sheet_xml = re.sub(rf'(<(?:dimension|autoFilter|sortState) ref="[A-Z]+\d+:){old_l}(\d+")',
                       rf"\g<1>{new_l}\g<2>", sheet_xml)
    for part in z.namelist():
        if part.startswith("xl/pivotCache/pivotCacheDefinition") and part.endswith(".xml"):
            pc = (parts[part] if part in parts else z.read(part)).decode("utf-8")
            pat = rf'(<worksheetSource ref="[A-Z]+\d+:){old_l}(\d+" sheet="{re.escape(name)}")'
            if re.search(pat, pc):
                pc = re.sub(pat, rf"\g<1>{new_l}\g<2>", pc)
                if "refreshOnLoad" not in pc:
                    pc = pc.replace("<pivotCacheDefinition ", '<pivotCacheDefinition refreshOnLoad="1" ', 1)
                parts[part] = pc.encode("utf-8")
    return sheet_xml


def write_zip(z, dst, parts):
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as out:
        for item in z.infolist():
            out.writestr(item, parts.get(item.filename, z.read(item.filename)))


def process_xlsx(src, dst):
    z = zipfile.ZipFile(src)
    name, path, cells = find_data_sheet(z)
    header_row, header, data_rows, rows = table(cells)
    values = compute(header, rows)
    if not values:
        sys.exit("nothing to do: roll columns already present")
    new_cols = [(c, dict(zip(data_rows, v))) for c, v in values.items()]
    parts = {}
    xml = append_columns(z.read(path).decode("utf-8"), name, header_row, len(header), new_cols, z, parts)
    parts[path] = xml.encode("utf-8")
    write_zip(z, dst, parts)
    first = col_letter(len(header) + 1)
    print(f"sheet '{name}': added {', '.join(values)} starting at column {first}", file=sys.stderr)


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__.strip().split("Usage:")[1].strip())
    src = Path(args[0])
    dst = Path(args[args.index("--out") + 1]) if "--out" in args else src.with_name(f"{src.stem}_roll{src.suffix}")
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
