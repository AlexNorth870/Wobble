# Wobble Replay Tools

Offline reprocessing of Wobble recordings on the Mac — no iPhone, no Simulator.
Iterate on the stroke-rate algorithm against real recorded data in seconds.

## Layout

- `Sources/StrokeAnalysis/` — pure, framework-free algorithm module (Foundation only).
  `StrokeAnalysis.swift` is lifted verbatim from the iOS app's
  `DataRecorder.computeStrokeRate()`, so results here match the phone exactly.
  This is the module the iOS app should eventually call too, so live == replay.
- `Sources/wobble-replay/` — command-line tool.
- `Tests/StrokeAnalysisTests/` — golden test proving replay reproduces the rate
  the app logged live (fixture: `Fixtures/sample.csv`).

## Toolchain note

XCTest ships with Xcode, not the standalone Command Line Tools. If `swift test`
reports `no such module 'XCTest'`, prefix commands with the Xcode developer dir
(no `sudo`, doesn't change your global setting):

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

`swift build` and `swift run` work with either toolchain.

## Use

Reprocess a recording and write per-row results:

    swift run wobble-replay <input.csv> --out results.csv

Prints a summary (detection rate, mean spm, agreement with the recorded values)
to stderr. The output CSV has `stroke_rate_original_spm` (as logged live) next to
`stroke_rate_new_spm` (recomputed) for easy diffing in a spreadsheet.

Run the golden test:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

## Iterating on the algorithm

Edit `Sources/StrokeAnalysis/StrokeAnalysis.swift` (the detector) or tweak
`StrokeParams`, then re-run `wobble-replay`. Because `stroke_rate_new_spm` is
recomputed, the effect of your change shows up immediately against real data.

Only `surge_g` is required to test a new stroke-rate detector. Changing how surge
itself is projected (the axis logic) needs `world_accel_x/y_g`, which older
recordings predate — add those columns to the app's logger to make future files
fully self-contained.

## Roll-only wobble for existing recordings

`scripts/add_roll_wobble.py` adds roll-only wobble columns computed the way the app
now calculates wobble: rotation rate rotated into the world frame and projected onto
the GPS course, so only side-to-side roll counts (pitch from the stroke and yaw from
steering are excluded).

- `wobble_roll_deg` — |roll rate| averaged over a rolling 10 s window (as the app shows).
- `roll_rate_deg_s` — instantaneous roll rate, signed: positive = rolling toward
  starboard, negative = toward port. Blank until the session's first GPS course.

Only columns not already present are added.

    python3 scripts/add_roll_wobble.py wobble_2026-10-04_10-21-40.csv
    python3 scripts/add_roll_wobble.py wobble_2026-10-04_combined.xlsx

Writes `<name>_roll.csv` / `<name>_roll.xlsx` next to the input (or `--out <path>`);
the input is never modified. Standard library only. Rows may be in any order: each
session (`source_file`, or `user_uuid` + `track`) is computed in stopwatch order. For
Excel the columns are spliced into the sheet XML so charts, pivot tables, sorts,
filters and hidden rows are kept; pivot caches on the sheet are widened and refresh on open.

## Reprocess a recording with the current algorithms

`scripts/reprocess.py` recomputes `stroke_rate_spm` with the app's fused detector
(the Swift `FusedAnalyzer`, built and run automatically) and `surge_g`, and adds the
roll columns if they are missing. The fused detector finds the dominant rhythm of
pitch, gravity z and GPS speed over a 15 s window. Surge is not used for the rate:
a single stroke's surge is noisy and lopsided (broad deceleration, short sharp push),
so detectors timing its onsets often counted a stroke twice. It is also available
as `wobble-replay <file.csv> --method fused`.

    python3 scripts/reprocess.py wobble_2026-10-04_Full_combined.xlsx

Writes `<name>_reprocessed.xlsx` / `.csv`; the input is never modified. Surge is
always rebuilt from the logged orientation and user acceleration with the app's
projection, never taken from the file: until October 2026 the app rotated
acceleration with CMRotationMatrix itself instead of its transpose, so logged
`surge_g` mixed in vertical motion (gravity came out ~40° from straight down).
Recordings from June 2026 and earlier used an arbitrary yaw reference, so their
surge is not truly fore-aft either way.
