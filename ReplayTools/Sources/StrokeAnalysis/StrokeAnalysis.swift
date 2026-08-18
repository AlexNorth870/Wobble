import Foundation

/// Tunable constants for the stroke-rate detector. Defaults match the values
/// hard-coded in the iOS app's `DataRecorder` at the time of extraction.
public struct StrokeParams: Sendable {
    /// Seconds between samples (the app records at 10 Hz).
    public var sampleInterval: Double = 0.1
    /// Rolling window length in samples (100 = 10 s).
    public var bufferSize = 100
    /// 50 spm = 1.2 s = 12 samples.
    public var minLag = 12
    /// 10 spm = 6.0 s = 60 samples.
    public var maxLag = 60
    /// Minimum surge RMS (g) over the last second to report a rate.
    public var minActivity = 0.04
    /// Minimum normalized autocorrelation peak (0...1) required to trust a reading.
    public var minConfidence = 0.15
    /// Trailing moving-average window (samples) applied to surge before the
    /// stroke-rate calculation. 1 = no smoothing (raw surge, original behaviour).
    public var smoothingWindow = 1

    public init() {}
}

/// Estimate stroke rate (strokes per minute) from a buffer of fore-aft surge
/// acceleration via autocorrelation. Returns 0 when the signal is too weak or
/// non-periodic to trust.
///
/// This is lifted verbatim from `DataRecorder.computeStrokeRate()` so the CLI
/// and tests exercise exactly the algorithm that runs on the phone.
public func computeStrokeRate(surgeBuffer: [Double],
                              params: StrokeParams = StrokeParams()) -> Double {
    let n = surgeBuffer.count
    guard n > params.maxLag else { return 0 }

    // Only calculate if the recent surge signal carries enough amplitude
    let recentSamples = surgeBuffer.suffix(10)
    guard recentSamples.count == 10 else { return 0 }
    let recentRMS = (recentSamples.map { $0 * $0 }.reduce(0, +) / 10.0).squareRoot()
    guard recentRMS > params.minActivity else { return 0 }

    // Subtract mean to center signal around zero
    let mean = surgeBuffer.reduce(0, +) / Double(n)
    let centered = surgeBuffer.map { $0 - mean }

    // Signal energy (lag-0 autocorrelation) used to normalize peaks into [-1, 1]
    let variance = centered.map { $0 * $0 }.reduce(0, +) / Double(n)
    guard variance > 0 else { return 0 }

    // Autocorrelation: find lag with highest normalized correlation in stroke rate range
    var bestCorr = -Double.infinity
    var bestLag = 0

    for lag in params.minLag...params.maxLag {
        guard lag < n else { continue }
        var corr = 0.0
        let count = n - lag
        for i in 0..<count {
            corr += centered[i] * centered[i + lag]
        }
        // Biased estimator (divide by constant n) then normalize by variance,
        // giving a true autocorrelation coefficient in [-1, 1] comparable across lags
        corr = (corr / Double(n)) / variance
        if corr > bestCorr {
            bestCorr = corr
            bestLag = lag
        }
    }

    // Suppress weak/non-periodic readings rather than reporting noise
    guard bestLag > 0, bestCorr >= params.minConfidence else { return 0 }
    let periodSeconds = Double(bestLag) * params.sampleInterval
    return 60.0 / periodSeconds
}

/// Stateful wrapper that reproduces the app's rolling-buffer behaviour: push one
/// surge sample per tick and read back the stroke rate the detector would report
/// at that instant.
// MARK: - Cycle-counting detector

/// Parameters for the cycle-counting stroke detector, which counts surge cycles
/// in a trailing window and reports the average rate. Unlike autocorrelation this
/// handles a varying stroke rate (it matches hand-counting strokes over time).
public struct CycleParams: Sendable {
    public var sampleInterval = 0.1
    /// Trailing moving-average applied to surge before cycle detection.
    public var smoothingWindow = 10
    /// Length of the trailing window over which cycles are counted, in seconds.
    public var windowSeconds = 20.0
    /// Hysteresis threshold as a fraction of the window's surge RMS. A stroke is
    /// counted each time the signal rises above +frac·RMS after dropping below
    /// -frac·RMS, which rejects small jitter without a fixed amplitude gate.
    public var thresholdFraction = 0.3
    /// Windows quieter than this RMS (g) report no rate (boat at rest / noise).
    public var minRMS = 0.005
    /// Require at least this many seconds of data before reporting a rate.
    public var minSeconds = 5.0

    public init() {}
}

/// Count surge cycles in a (smoothed, mean-subtracted internally) window via
/// hysteresis and return the average stroke rate over that window.
public func cycleStrokeRate(window: [Double], params: CycleParams = CycleParams()) -> Double {
    let n = window.count
    let span = Double(n) * params.sampleInterval
    guard span >= params.minSeconds, n >= 2 else { return 0 }

    let mean = window.reduce(0, +) / Double(n)
    let centered = window.map { $0 - mean }
    let rms = (centered.map { $0 * $0 }.reduce(0, +) / Double(n)).squareRoot()
    guard rms > params.minRMS else { return 0 }

    let h = params.thresholdFraction * rms
    var high = false
    var count = 0
    for v in centered {
        if !high, v > h {
            count += 1
            high = true
        } else if high, v < -h {
            high = false
        }
    }
    return 60.0 * Double(count) / span
}

/// Streaming wrapper for the cycle-counting detector. Push one raw surge sample
/// per tick; it smooths, maintains a trailing window, and returns the average
/// stroke rate over that window.
public struct CycleAnalyzer {
    public let params: CycleParams
    private var rawBuffer: [Double] = []
    private var window: [Double] = []

    private var maxSamples: Int {
        max(2, Int((params.windowSeconds / params.sampleInterval).rounded()))
    }

    public init(params: CycleParams = CycleParams()) {
        self.params = params
    }

    public mutating func push(_ surge: Double) -> Double {
        rawBuffer.append(surge)
        if rawBuffer.count > params.smoothingWindow {
            rawBuffer.removeFirst()
        }
        let smoothed = rawBuffer.reduce(0, +) / Double(rawBuffer.count)

        window.append(smoothed)
        if window.count > maxSamples {
            window.removeFirst()
        }
        return cycleStrokeRate(window: window, params: params)
    }

    public mutating func reset() {
        rawBuffer = []
        window = []
    }
}

// MARK: - Interval detector

/// Parameters for the interval-based detector: it times the gaps between recent
/// stroke onsets and reports 60 / (mean interval). Unlike cycle-counting this
/// produces a continuous (non-quantized) rate and responds on each new stroke.
public struct IntervalParams: Sendable {
    public var sampleInterval = 0.1
    /// Trailing moving-average applied to surge before onset detection.
    public var smoothingWindow = 10
    /// Trailing window (s) used to estimate the mean/RMS that set the threshold.
    public var rmsWindowSeconds = 12.0
    /// Onset threshold as a fraction of the window RMS (hysteresis).
    public var thresholdFraction = 0.3
    /// Windows quieter than this RMS (g) report no rate (at rest / noise).
    public var minRMS = 0.005
    /// Average the interval over this many of the most recent strokes.
    public var strokesToAverage = 3
    /// If no onset occurs within this many seconds, report 0 (≈ a 10 spm floor).
    public var maxGapSeconds = 6.0
    /// Require this many seconds of data before reporting a rate.
    public var minSeconds = 3.0
    /// Exponential smoothing factor (alpha) applied to the output rate each tick.
    /// 1.0 = no smoothing; smaller = steadier but slower to settle. At 10 Hz,
    /// alpha≈0.1 gives roughly a 1 s settling time.
    public var outputSmoothing = 0.1

    public init() {}
}

/// Streaming interval-based stroke detector. Push one raw surge sample per tick;
/// it smooths, detects stroke onsets via hysteresis, and returns 60 / (mean of
/// the last few inter-onset intervals).
public struct IntervalAnalyzer {
    public let params: IntervalParams
    private var rawBuffer: [Double] = []
    private var rmsWindow: [Double] = []
    private var high = false
    private var onsetTimes: [Double] = []
    private var samples = 0
    private var smoothedRate = 0.0

    private var rmsMaxSamples: Int {
        max(2, Int((params.rmsWindowSeconds / params.sampleInterval).rounded()))
    }

    public init(params: IntervalParams = IntervalParams()) {
        self.params = params
    }

    public mutating func push(_ surge: Double) -> Double {
        let now = Double(samples) * params.sampleInterval
        samples += 1

        rawBuffer.append(surge)
        if rawBuffer.count > params.smoothingWindow { rawBuffer.removeFirst() }
        let smoothed = rawBuffer.reduce(0, +) / Double(rawBuffer.count)

        rmsWindow.append(smoothed)
        if rmsWindow.count > rmsMaxSamples { rmsWindow.removeFirst() }

        let n = rmsWindow.count
        let mean = rmsWindow.reduce(0, +) / Double(n)
        let rms = (rmsWindow.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n)).squareRoot()

        // Warm-up and idle gate
        guard now + params.sampleInterval >= params.minSeconds, rms > params.minRMS else {
            return emit(0)
        }

        // Hysteresis onset detection on the mean-subtracted smoothed value
        let centered = smoothed - mean
        let threshold = params.thresholdFraction * rms
        if !high, centered > threshold {
            high = true
            onsetTimes.append(now)
            if onsetTimes.count > params.strokesToAverage + 1 { onsetTimes.removeFirst() }
        } else if high, centered < -threshold {
            high = false
        }

        guard let last = onsetTimes.last, onsetTimes.count >= 2 else { return emit(0) }
        // No stroke for too long → treat as stopped
        if now - last > params.maxGapSeconds { return emit(0) }

        let intervals = zip(onsetTimes.dropFirst(), onsetTimes).map { $0 - $1 }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0 else { return emit(0) }
        return emit(60.0 / avg)
    }

    /// Apply exponential smoothing to the output rate. A zero (idle/stopped)
    /// resets the smoother so the number drops promptly rather than decaying.
    private mutating func emit(_ raw: Double) -> Double {
        if raw <= 0 {
            smoothedRate = 0
        } else if smoothedRate <= 0 {
            smoothedRate = raw   // seed on first stroke to avoid a slow ramp from 0
        } else {
            smoothedRate = params.outputSmoothing * raw + (1 - params.outputSmoothing) * smoothedRate
        }
        return smoothedRate
    }

    public mutating func reset() {
        rawBuffer = []
        rmsWindow = []
        high = false
        onsetTimes = []
        samples = 0
        smoothedRate = 0
    }
}

// MARK: - Autocorrelation detector

public struct StrokeAnalyzer {
    public let params: StrokeParams
    private var rawBuffer: [Double] = []    // last `smoothingWindow` raw surge samples
    private var surgeBuffer: [Double] = []  // smoothed surge fed to the detector

    public init(params: StrokeParams = StrokeParams()) {
        self.params = params
    }

    /// Append one raw surge sample and return the current stroke-rate estimate.
    /// The sample is first passed through a trailing moving average of length
    /// `params.smoothingWindow` before entering the autocorrelation buffer.
    public mutating func push(_ surge: Double) -> Double {
        rawBuffer.append(surge)
        if rawBuffer.count > params.smoothingWindow {
            rawBuffer.removeFirst()
        }
        let smoothed = rawBuffer.reduce(0, +) / Double(rawBuffer.count)

        surgeBuffer.append(smoothed)
        if surgeBuffer.count > params.bufferSize {
            surgeBuffer.removeFirst()
        }
        return computeStrokeRate(surgeBuffer: surgeBuffer, params: params)
    }

    public mutating func reset() {
        rawBuffer = []
        surgeBuffer = []
    }
}
