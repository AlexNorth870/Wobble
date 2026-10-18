import Foundation
import StrokeAnalysis

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: wobble-replay <input.csv> [--out <output.csv>]", code: 2)
}

let inputPath = args[1]
var outputPath: String?
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outputPath = args[i + 1]
}

func stringArg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let method = stringArg("--method") ?? "acf"   // "acf" (autocorrelation), "cycle", "interval" or "fused"

var params = StrokeParams()
if let w = stringArg("--smooth").flatMap(Int.init), w >= 1 { params.smoothingWindow = w }
if let a = stringArg("--min-activity").flatMap(Double.init), a >= 0 { params.minActivity = a }

var cycleParams = CycleParams()
if let w = stringArg("--smooth").flatMap(Int.init), w >= 1 { cycleParams.smoothingWindow = w }
if let s = stringArg("--window").flatMap(Double.init), s > 0 { cycleParams.windowSeconds = s }
if let f = stringArg("--threshold").flatMap(Double.init), f > 0 { cycleParams.thresholdFraction = f }

var intervalParams = IntervalParams()
if let w = stringArg("--smooth").flatMap(Int.init), w >= 1 { intervalParams.smoothingWindow = w }
if let s = stringArg("--window").flatMap(Double.init), s > 0 { intervalParams.rmsWindowSeconds = s }
if let f = stringArg("--threshold").flatMap(Double.init), f > 0 { intervalParams.thresholdFraction = f }
if let k = stringArg("--strokes").flatMap(Int.init), k >= 1 { intervalParams.strokesToAverage = k }
if let a = stringArg("--smooth-out").flatMap(Double.init), a > 0, a <= 1 { intervalParams.outputSmoothing = a }

var fusedParams = FusedParams()
if let s = stringArg("--window").flatMap(Double.init), s > 0 { fusedParams.windowSeconds = s }

// One step function per method; each takes a raw surge sample (plus pitch,
// gravity-z and speed, which only the fused detector uses) and returns spm.
var acf = StrokeAnalyzer(params: params)
var cyc = CycleAnalyzer(params: cycleParams)
var itv = IntervalAnalyzer(params: intervalParams)
var fus = FusedAnalyzer(params: fusedParams)
let step: (_ surge: Double, _ pitch: Double, _ gravityZ: Double, _ speed: Double) -> Double
switch method {
case "cycle":    step = { s, _, _, _ in cyc.push(s) }
case "interval": step = { s, _, _, _ in itv.push(s) }
case "acf":      step = { s, _, _, _ in acf.push(s) }
case "fused":    step = { s, p, g, v in fus.push(surge: s, pitch: p, gravityZ: g, speed: v) }
default:         fail("error: --method must be 'acf', 'cycle', 'interval', or 'fused'")
}

let csv: WobbleCSV
do {
    csv = try WobbleCSV(contentsOf: URL(fileURLWithPath: inputPath))
} catch {
    fail("error: could not read \(inputPath): \(error)")
}

guard csv.hasColumn("surge_g") else {
    fail("error: file has no surge_g column (need a recording that logs surge)")
}
if method == "fused" {
    for name in ["pitch_rad", "gravity_z_g", "speed_mps"] where !csv.hasColumn(name) {
        fail("error: --method fused needs a \(name) column")
    }
}

let binSeconds = stringArg("--bin").flatMap(Double.init) ?? 15.0

// Re-run the stroke-rate detector over the recorded surge, one sample per tick,
// reproducing the app's rolling-buffer behaviour, and collect context columns.
struct OutRow { let t, surge, speed, course, orig, new: Double }
var rows: [OutRow] = []
var smoothWindow: [Double] = []   // trailing-10 smoothed surge, parallel to the detector
var smoothed: [Double] = []       // one smoothed value per output row (for the bin rate)

var total = 0
var origNonZero = 0
var newNonZero = 0
var matched = 0
var newSum = 0.0

for row in csv.rows {
    guard let surge = csv.double(row, "surge_g") else { continue }
    let elapsed = csv.double(row, "stopwatch_time_s") ?? 0
    let speed = csv.double(row, "speed_mps") ?? 0
    let course = csv.double(row, "course_deg") ?? -1
    let orig = csv.double(row, "stroke_rate_spm") ?? 0
    let new = step(surge, csv.double(row, "pitch_rad") ?? 0, csv.double(row, "gravity_z_g") ?? 0, speed)
    let newRounded = (new * 10).rounded() / 10  // app logs stroke rate at %.1f

    smoothWindow.append(surge)
    if smoothWindow.count > 10 { smoothWindow.removeFirst() }
    smoothed.append(smoothWindow.reduce(0, +) / Double(smoothWindow.count))

    total += 1
    if orig > 0 { origNonZero += 1 }
    if newRounded > 0 { newNonZero += 1; newSum += newRounded }
    if abs(newRounded - orig) < 0.05 { matched += 1 }

    rows.append(OutRow(t: elapsed, surge: surge, speed: speed, course: course, orig: orig, new: newRounded))
}

guard total > 0 else { fail("error: no data rows with a surge_g value") }

// Coarse per-bin rate: precompute one cycle-count rate per fixed stopwatch bin
// (a steadier cross-check than the streaming rate), then assign it to each row.
var binRates: [Int: Double] = [:]
let maxBin = Int(rows[rows.count - 1].t / binSeconds)
for b in 0...maxBin {
    let lo = Double(b) * binSeconds, hi = lo + binSeconds
    let idx = rows.indices.filter { rows[$0].t >= lo && rows[$0].t < hi }
    guard idx.count >= 2 else { binRates[b] = 0; continue }
    let seg = idx.map { smoothed[$0] }
    let mean = seg.reduce(0, +) / Double(seg.count)
    let centered = seg.map { $0 - mean }
    let rms = (centered.map { $0 * $0 }.reduce(0, +) / Double(seg.count)).squareRoot()
    guard rms > cycleParams.minRMS else { binRates[b] = 0; continue }
    let h = cycleParams.thresholdFraction * rms
    var high = false, count = 0
    for v in centered {
        if !high, v > h { count += 1; high = true }
        else if high, v < -h { high = false }
    }
    let span = (rows[idx.last!].t - rows[idx.first!].t) + 0.1
    binRates[b] = 60.0 * Double(count) / span
}

let binLabel = "stroke_rate_bin\(Int(binSeconds))s_spm"
var outLines = ["stopwatch_time_s,surge_g,speed_mps,course_deg,stroke_rate_original_spm,stroke_rate_new_spm,\(binLabel)"]
for r in rows {
    let br = binRates[Int(r.t / binSeconds)] ?? 0
    outLines.append(String(format: "%.3f,%.6f,%.4f,%.1f,%.1f,%.1f,%.1f",
                           r.t, r.surge, r.speed, r.course, r.orig, r.new, br))
}

if let outputPath {
    do {
        try outLines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        fail("error: could not write \(outputPath): \(error)")
    }
}

// Summary to stderr so stdout stays clean for piping.
let pct = { (x: Int) in String(format: "%.1f%%", 100.0 * Double(x) / Double(total)) }
var summary = ""
summary += "method:                   \(method)\n"
if method == "fused" {
    summary += String(format: "spectrum window:          %.0f s\n", fusedParams.windowSeconds)
} else if method == "cycle" {
    summary += "smoothing window:         \(cycleParams.smoothingWindow) sample(s)\n"
    summary += String(format: "count window:             %.0f s\n", cycleParams.windowSeconds)
    summary += String(format: "threshold fraction:       %.2f\n", cycleParams.thresholdFraction)
} else {
    summary += "smoothing window:         \(params.smoothingWindow) sample(s)\n"
    summary += String(format: "min activity gate:        %.4f g\n", params.minActivity)
}
summary += "rows analyzed:            \(total)\n"
summary += "original detected rate:   \(origNonZero) rows (\(pct(origNonZero)))\n"
summary += "recomputed detected rate: \(newNonZero) rows (\(pct(newNonZero)))\n"
if newNonZero > 0 {
    summary += String(format: "recomputed mean rate:     %.1f spm\n", newSum / Double(newNonZero))
}
summary += "agreement with original:  \(matched)/\(total) (\(pct(matched)))\n"
if let outputPath {
    summary += "wrote:                    \(outputPath)\n"
} else {
    summary += "(pass --out <file.csv> to write per-row results)\n"
}
FileHandle.standardError.write(Data(summary.utf8))
