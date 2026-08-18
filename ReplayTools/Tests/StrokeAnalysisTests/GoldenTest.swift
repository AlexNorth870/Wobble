import XCTest
@testable import StrokeAnalysis

final class GoldenTest: XCTestCase {

    /// Replaying the recorded surge through the extracted algorithm must
    /// reproduce the stroke rate the app logged live. This proves the extraction
    /// is faithful before any algorithm changes are made.
    ///
    /// Note: the fixture stores `surge_g` at 6-decimal precision, so feeding it
    /// back in can occasionally flip a borderline autocorrelation lag versus the
    /// full-precision value used live. We therefore require high (not perfect)
    /// agreement and surface any mismatches.
    func testReplayReproducesRecordedStrokeRate() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "csv"),
            "missing sample.csv fixture"
        )
        let csv = try WobbleCSV(contentsOf: url)
        XCTAssertTrue(csv.hasColumn("surge_g"))

        var analyzer = StrokeAnalyzer()
        var total = 0
        var mismatches = 0
        var firstMismatch: String?

        for row in csv.rows {
            guard let surge = csv.double(row, "surge_g") else { continue }
            let orig = csv.double(row, "stroke_rate_spm") ?? 0
            let new = analyzer.push(surge)
            let newRounded = (new * 10).rounded() / 10

            total += 1
            if abs(newRounded - orig) >= 0.05 {
                mismatches += 1
                if firstMismatch == nil {
                    let t = csv.double(row, "stopwatch_time_s") ?? 0
                    firstMismatch = String(format: "t=%.3f original=%.1f recomputed=%.1f", t, orig, newRounded)
                }
            }
        }

        XCTAssertGreaterThan(total, 0)
        let agreement = Double(total - mismatches) / Double(total)
        print(String(format: "golden agreement: %.2f%% (%d/%d mismatched)%@",
                     agreement * 100, mismatches, total,
                     firstMismatch.map { " first: \($0)" } ?? ""))
        XCTAssertGreaterThan(agreement, 0.98, "replay diverged from recorded stroke rate")
    }

    /// Ground truth: the phone owner hand-counted 11 surge cycles from t=35 s to
    /// the end of the recording (~32 s) → ~22 spm average. The cycle-counting
    /// detector must reproduce that count, unlike autocorrelation which locks
    /// onto the most-common (slow) stroke and under-reports on a varying rate.
    func testCycleCounterMatchesHandCount() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "csv"))
        let csv = try WobbleCSV(contentsOf: url)

        // Smoothed surge over the ground-truth window (t >= 35).
        var raw: [Double] = []
        var window: [Double] = []
        for row in csv.rows {
            guard let surge = csv.double(row, "surge_g"),
                  let t = csv.double(row, "stopwatch_time_s") else { continue }
            raw.append(surge)
            let w = min(raw.count, 10)
            let smoothed = raw.suffix(w).reduce(0, +) / Double(w)
            if t >= 35 { window.append(smoothed) }
        }

        let rate = cycleStrokeRate(window: window)
        let span = Double(window.count) * 0.1
        let cycles = rate * span / 60.0
        print(String(format: "cycle count over t>=35: %.0f cycles in %.1fs = %.1f spm", cycles, span, rate))

        XCTAssertEqual(cycles, 11, accuracy: 1, "expected ~11 hand-counted cycles")
        XCTAssertEqual(rate, 22, accuracy: 3, "expected ~22 spm average")
    }

    /// Second ground-truth recording: hand-counted 11 strokes from stopwatch
    /// 45–75 s (video available from t=44.5) → 22 spm. This window has a strong,
    /// moderately-steady signal, so both detectors should agree here.
    func testCycleCounterMatchesHandCount_file2() throws {
        let (cycles, rate) = try cycleRate(fixture: "sample2", from: 45, to: 75)
        print(String(format: "sample2 t=45..75: %.0f cycles = %.1f spm", cycles, rate))
        XCTAssertEqual(cycles, 11, accuracy: 1, "expected ~11 hand-counted cycles")
        XCTAssertEqual(rate, 22, accuracy: 3, "expected ~22 spm average")
    }

    /// The interval detector (K=3 + smoothing, the app's method) should track the
    /// hand count over file 2's ground-truth window and, unlike cycle-counting,
    /// produce continuous (non-quantized) values.
    func testIntervalMethodTracksHandCount_file2() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample2", withExtension: "csv"))
        let csv = try WobbleCSV(contentsOf: url)
        var itv = IntervalAnalyzer()   // defaults: K=3, output smoothing 0.1
        var rates: [Double] = []
        for row in csv.rows {
            guard let surge = csv.double(row, "surge_g"),
                  let t = csv.double(row, "stopwatch_time_s") else { continue }
            let r = itv.push(surge)
            if t >= 45, t <= 75, r > 0 { rates.append(r) }
        }
        let mean = rates.reduce(0, +) / Double(rates.count)
        let distinct = Set(rates.map { ($0 * 10).rounded() }).count
        print(String(format: "interval file2 t=45..75: mean=%.1f spm, distinct=%d", mean, distinct))
        XCTAssertEqual(mean, 20.5, accuracy: 3.5, "interval rate should track ~22 spm ground truth")
        XCTAssertGreaterThan(distinct, 20, "interval rate should be continuous, not quantized")
    }

    /// Count surge cycles over a stopwatch window of a fixture, using the same
    /// last-10 smoothing + hysteresis as the streaming detector.
    private func cycleRate(fixture: String, from t0: Double, to t1: Double,
                           params: CycleParams = CycleParams()) throws -> (cycles: Double, spm: Double) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "csv"))
        let csv = try WobbleCSV(contentsOf: url)
        var raw: [Double] = []
        var window: [Double] = []
        for row in csv.rows {
            guard let surge = csv.double(row, "surge_g"),
                  let t = csv.double(row, "stopwatch_time_s") else { continue }
            raw.append(surge)
            let w = min(raw.count, params.smoothingWindow)
            let smoothed = raw.suffix(w).reduce(0, +) / Double(w)
            if t >= t0 && t <= t1 { window.append(smoothed) }
        }
        let rate = cycleStrokeRate(window: window, params: params)
        let span = Double(window.count) * params.sampleInterval
        return (rate * span / 60.0, rate)
    }
}
