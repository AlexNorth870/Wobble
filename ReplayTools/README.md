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
