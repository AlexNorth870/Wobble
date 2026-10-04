import Foundation
import CoreLocation
import CoreMotion
import CloudKit
import CryptoKit

struct MinuteSummary {
    let minute: Int
    let avgPace: Double    // seconds per 500m (0 = no speed data)
    let avgStrokeRate: Double
    let avgWobble: Double
    let distanceM: Double  // total meters this minute (or full session when minute == 0)
}

class DataRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isRecording = false
    @Published var isArmed = false        // auto start: waiting for the boat to move
    @Published var lastSavedFilename: String?
    @Published var currentSpeedMps: Double = 0
    @Published var wobbleFactor: Double = 0
    @Published var strokeRate: Double = 0
    @Published var distanceTravelled: Double = 0
    @Published var sessionSummary: [MinuteSummary] = []
    @Published var showingSummary = false

    private struct DataPoint {
        let elapsed: Double
        let speed: Double
        let strokeRate: Double
        let wobble: Double
        let distanceM: Double  // incremental distance this sample (speed * 0.1)
    }
    private var dataPoints: [DataPoint] = []

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let isoFormatter = ISO8601DateFormatter()
    private let cloudDB = CKContainer(identifier: "iCloud.com.VT24NXHTS5.wobble").publicCloudDatabase
    private var pendingRecords: [CKRecord] = []

    private let userUUID: String = {
        if let existing = UserDefaults.standard.string(forKey: "wobble_user_uuid") {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "wobble_user_uuid")
        return new
    }()

    // 8-character SHA256 hash of the UUID for display and CSV
    // ultimately identifies each user, although with no personal information
    let shortUserID: String = {
        let raw = UserDefaults.standard.string(forKey: "wobble_user_uuid") ?? UUID().uuidString
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8).uppercased()
    }()

    // Track number — increments each time Start is pressed, persists across app restarts
    // This will be useful for identifying tracks
    // TODO:  add a table for track specific information such as weather, water conditions and team
    //  members (not required of course)
    private(set) var trackNumber: Int = UserDefaults.standard.integer(forKey: "wobble_track_number")

    private(set) var startDate: Date?

    // Auto start: once armed, recording begins when GPS speed reaches the threshold on
    // consecutive fixes. The start time is backdated to the first qualifying fix.
    private let autoStartSpeed = 1.5          // m/s, well above GPS noise and drift at the start line
    private let autoStartConsecutiveFixes = 2 // fixes above threshold required to trigger
    private var autoStartFixCount = 0
    private var autoStartFirstFixTime: Date?
    private var recordingTimer: Timer?
    private var csvRows: [String] = []
    private var currentLocation: CLLocation?
    // 10 seconds at 0.1s intervals = 100 samples
    private var rotationMagnitudeBuffer: [Double] = []
    private let wobbleBufferSize = 100
    // Stroke rate via interval timing of forward (surge) acceleration: detect
    // stroke onsets and report 60 / (mean recent inter-onset interval).
    private var rawSurgeBuffer: [Double] = []                         // recent raw surge, for smoothing
    private var smoothedSurgeBuffer: [Double] = []                    // trailing window of smoothed surge (for mean/RMS)
    private var strokeHigh = false                                    // hysteresis state (above/below threshold)
    private var strokeOnsetTimes: [Double] = []                      // times (s) of recent detected stroke onsets
    private var strokeSamples = 0                                     // sample counter, drives the internal clock
    private var strokeSmoothedRate = 0.0                             // EMA-smoothed output rate (spm)
    private var horizontalAccelBuffer: [(x: Double, y: Double)] = []  // world-horizontal accel, for the fallback axis
    private var lastForwardAxis: (x: Double, y: Double)?              // last known travel direction (world frame)
    private var axisSource: String = "none"                          // debug: which axis produced the last surge (A/B/held/none)
    private let axisBufferSize = 100      // 10 s of world-horizontal accel for the PCA fallback axis
    private let strokeSmoothingWindow = 10 // trailing surge moving average (~1 s) to cut jitter
    private let strokeWindowSize = 120     // 12 s at 0.1 s: window for the mean/RMS that sets the threshold
    private let strokeThresholdFraction = 0.3 // onset threshold as a fraction of window RMS
    private let strokeMinRMS = 0.005      // below this surge RMS the boat is treated as at rest (report 0)
    private let strokesToAverage = 3      // average the interval over this many recent strokes
    private let strokeMaxGapSeconds = 6.0 // no onset within this long -> report 0 (~10 spm floor)
    private let strokeMinSeconds = 3.0    // require this much data before reporting a rate
    private let strokeOutputSmoothing = 0.1 // EMA factor on the output rate (~1 s settling at 10 Hz)
    private let minCourseSpeed = 0.5      // m/s below which GPS course is unreliable (use fallback axis)
    private let pcaMinSamples = 20        // ~2 s of data before trusting the fallback (PCA) axis
    private let minSurgeVariance = 0.0025 // min horizontal accel variance (g^2) for a trustworthy fallback axis

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestWhenInUseAuthorization()
        pingFirstLaunchIfNeeded()
    }

    // Silently notify the developer that a user has installed and run the app.
    // Fires once ever: hits a plain HTML page on the website (which registers as a
    // page view) with the rower ID and app build number as query parameters. Fire-and-
    // forget, no UI. The "done" flag is only set on a successful request, so if the
    // first run has no signal it will retry on a later launch.
    // Hitting that page will cause a notification to be sent, let us know that
    // someone has installed and run this app.
    private func pingFirstLaunchIfNeeded() {
        let doneKey = "wobble_first_launch_pinged"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        var components = URLComponents(string: "https://www.wobblerowing.com/api/first-launch.html")
        components?.queryItems = [
            URLQueryItem(name: "id", value: shortUserID),
            URLQueryItem(name: "build", value: build)
        ]
        guard let url = components?.url else { return }

        URLSession.shared.dataTask(with: url) { _, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            UserDefaults.standard.set(true, forKey: doneKey)
        }.resume()
    }

    // Turn on GPS and wait for movement; the timer stays at zero until then.
    func arm() {
        guard !isRecording else { return }
        autoStartFixCount = 0
        autoStartFirstFixTime = nil
        isArmed = true
        locationManager.startUpdatingLocation()
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        locationManager.stopUpdatingLocation()
    }

    func start(at date: Date = Date()) {
        isArmed = false
        trackNumber += 1
        UserDefaults.standard.set(trackNumber, forKey: "wobble_track_number")
        startDate = date
        lastSavedFilename = nil
        csvRows = []
        rotationMagnitudeBuffer = []
        rawSurgeBuffer = []
        smoothedSurgeBuffer = []
        strokeHigh = false
        strokeOnsetTimes = []
        strokeSamples = 0
        strokeSmoothedRate = 0
        horizontalAccelBuffer = []
        lastForwardAxis = nil
        wobbleFactor = 0
        strokeRate = 0
        distanceTravelled = 0
        pendingRecords = []
        dataPoints = []
        sessionSummary = []
        showingSummary = false
        csvRows.append(
            "user_uuid," +
            "track," +
            "stopwatch_time_s," +
            "timestamp," +
            "latitude_deg," +
            "longitude_deg," +
            "altitude_m," +
            "speed_mps," +
            "pace_min_per_500m," +
            "course_deg," +
            "pitch_rad," +
            "roll_rad," +
            "yaw_rad," +
            "user_accel_x_g," +
            "user_accel_y_g," +
            "user_accel_z_g," +
            "gravity_x_g," +
            "gravity_y_g," +
            "gravity_z_g," +
            "rotation_rate_x_rads," +
            "rotation_rate_y_rads," +
            "rotation_rate_z_rads," +
            "wobble_factor_deg," +
            "stroke_rate_spm," +
            "distance_cumulative_m," +
            "surge_g," +          // debug: projected fore-aft acceleration fed to stroke detector
            "axis_source"         // debug: A=GPS course, B=PCA fallback, held=last axis, none
        )

        locationManager.startUpdatingLocation()

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.02
            // True-north reference so GPS course and acceleration share a frame
            motionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical)
        }

        isRecording = true

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordDataPoint()
            // Update speed display once per second (matches the 1 Hz GPS update)
            let elapsed = Date().timeIntervalSince(self.startDate ?? Date())
            if Int(elapsed * 10) % 10 == 0 {
                let speed = max(self.currentLocation?.speed ?? 0, 0)
                DispatchQueue.main.async { self.currentSpeedMps = speed }
            }
        }
    }

    func stop() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        currentSpeedMps = 0
        wobbleFactor = 0
        strokeRate = 0
        rotationMagnitudeBuffer = []
        rawSurgeBuffer = []
        smoothedSurgeBuffer = []
        strokeHigh = false
        strokeOnsetTimes = []
        strokeSamples = 0
        strokeSmoothedRate = 0
        horizontalAccelBuffer = []
        lastForwardAxis = nil
        saveCSV()
        uploadToCloudKit()
        computeSessionSummary()
    }

    private func recordDataPoint() {
        guard let startDate else { return }

        let elapsed = Date().timeIntervalSince(startDate)
        let timestamp = isoFormatter.string(from: Date())

        let lat    = currentLocation?.coordinate.latitude  ?? 0.0
        let lon    = currentLocation?.coordinate.longitude ?? 0.0
        let alt    = currentLocation?.altitude             ?? 0.0
        let speed  = max(currentLocation?.speed  ?? 0.0, 0.0)
        let course = max(currentLocation?.course ?? 0.0, 0.0)

        var pitch: Double = 0, roll: Double = 0, yaw: Double = 0
        var ax: Double = 0, ay: Double = 0, az: Double = 0
        var gx: Double = 0, gy: Double = 0, gz: Double = 0
        var gravX: Double = 0, gravY: Double = 0, gravZ: Double = 0
        // user acceleration rotated into the world frame (X = true north, Y = west)
        var worldAccelX: Double = 0, worldAccelY: Double = 0

        if let motion = motionManager.deviceMotion {
            pitch = motion.attitude.pitch
            roll  = motion.attitude.roll
            yaw   = motion.attitude.yaw
            ax    = motion.userAcceleration.x
            ay    = motion.userAcceleration.y
            az    = motion.userAcceleration.z
            gravX = motion.gravity.x
            gravY = motion.gravity.y
            gravZ = motion.gravity.z
            gx    = motion.rotationRate.x
            gy    = motion.rotationRate.y
            gz    = motion.rotationRate.z
            // Rotate device-frame user acceleration into the world frame
            let m = motion.attitude.rotationMatrix
            worldAccelX = m.m11 * ax + m.m12 * ay + m.m13 * az
            worldAccelY = m.m21 * ax + m.m22 * ay + m.m23 * az
        }

        let pace = speed > 0.1 ? (500.0 / speed) / 60.0 : 0.0

        // Accumulate distance: velocity × sample interval (0.1 s)
        let sampleDistance = speed * 0.1
        distanceTravelled += sampleDistance

        // Stroke rate via cycle counting of forward (surge) acceleration.
        // Project world-horizontal acceleration onto the travel direction so only
        // fore-aft surge is used; vertical bob and lateral movement project to ~0.
        horizontalAccelBuffer.append((x: worldAccelX, y: worldAccelY))
        if horizontalAccelBuffer.count > axisBufferSize {
            horizontalAccelBuffer.removeFirst()
        }
        let rawCourse = currentLocation?.course ?? -1
        let surge: Double
        if let axis = forwardAxis(rawCourse: rawCourse, speed: speed) {
            surge = worldAccelX * axis.x + worldAccelY * axis.y
        } else {
            surge = 0
        }
        // Smooth surge with a trailing moving average, then keep a 12 s window of
        // smoothed surge for the cycle-counting stroke detector.
        rawSurgeBuffer.append(surge)
        if rawSurgeBuffer.count > strokeSmoothingWindow {
            rawSurgeBuffer.removeFirst()
        }
        let smoothedSurge = rawSurgeBuffer.reduce(0, +) / Double(rawSurgeBuffer.count)
        smoothedSurgeBuffer.append(smoothedSurge)
        if smoothedSurgeBuffer.count > strokeWindowSize {
            smoothedSurgeBuffer.removeFirst()
        }
        let currentStrokeRate = computeStrokeRate()
        DispatchQueue.main.async { self.strokeRate = currentStrokeRate }

        // Wobble factor: rolling 10s average of rotation rate magnitude
        let magnitude = sqrt(gx * gx + gy * gy + gz * gz)
        rotationMagnitudeBuffer.append(magnitude)
        if rotationMagnitudeBuffer.count > wobbleBufferSize {
            rotationMagnitudeBuffer.removeFirst()
        }
        let avgMagnitudeRads = rotationMagnitudeBuffer.reduce(0, +) / Double(rotationMagnitudeBuffer.count)
        let currentWobble = avgMagnitudeRads * 180.0 / .pi
        DispatchQueue.main.async { self.wobbleFactor = currentWobble }

        let row = "\(shortUserID),\(trackNumber)," + String(
            format: "%.3f,%@,%.8f,%.8f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.1f,%.2f,%.6f,%@",
            elapsed, timestamp,
            lat, lon, alt, speed, pace, course,
            pitch, roll, yaw,
            ax, ay, az,
            gravX, gravY, gravZ,
            gx, gy, gz,
            currentWobble,
            currentStrokeRate,
            distanceTravelled,
            surge,
            axisSource
        )
        csvRows.append(row)
        dataPoints.append(DataPoint(elapsed: elapsed, speed: speed, strokeRate: currentStrokeRate, wobble: currentWobble, distanceM: sampleDistance))

        // Build CloudKit record for this data point
        let record = CKRecord(recordType: "WobbleDataPoint")
        record["userUUID"]            = shortUserID
        record["track"]               = trackNumber
        record["timestamp"]           = Date()
        record["stopwatchTime"]       = elapsed
        record["latitude"]            = lat
        record["longitude"]           = lon
        record["altitude"]            = alt
        record["speedMps"]            = speed
        record["paceMinPer500m"]      = pace
        record["courseDeg"]           = course
        record["pitchRad"]            = pitch
        record["rollRad"]             = roll
        record["yawRad"]              = yaw
        record["userAccelX"]          = ax
        record["userAccelY"]          = ay
        record["userAccelZ"]          = az
        record["gravityX"]            = gravX
        record["gravityY"]            = gravY
        record["gravityZ"]            = gravZ
        record["rotationRateX"]       = gx
        record["rotationRateY"]       = gy
        record["rotationRateZ"]       = gz
        record["wobbleFactorDeg"]     = currentWobble
        record["strokeRateSpm"]       = currentStrokeRate
        record["distanceCumulativeM"] = distanceTravelled
        pendingRecords.append(record)
    }

    // MARK: - Session Summary

    private func computeSessionSummary() {
        guard !dataPoints.isEmpty else { return }

        // Group data points by minute (1-based)
        var byMinute: [Int: [DataPoint]] = [:]
        for point in dataPoints {
            let minute = Int(point.elapsed / 60) + 1
            byMinute[minute, default: []].append(point)
        }

        let minutes = byMinute.keys.sorted()
        var summaries: [MinuteSummary] = minutes.map { minute in
            let points = byMinute[minute]!
            let avgSpeed = points.map { $0.speed }.reduce(0, +) / Double(points.count)
            let avgPace = avgSpeed > 0.1 ? 500.0 / avgSpeed : 0
            let avgStroke = points.map { $0.strokeRate }.reduce(0, +) / Double(points.count)
            let avgWobble = points.map { $0.wobble }.reduce(0, +) / Double(points.count)
            let totalDist = points.map { $0.distanceM }.reduce(0, +)
            return MinuteSummary(minute: minute, avgPace: avgPace, avgStrokeRate: avgStroke, avgWobble: avgWobble, distanceM: totalDist)
        }

        // Whole session totals/averages as final row (minute = 0 means "total")
        let allSpeed = dataPoints.map { $0.speed }.reduce(0, +) / Double(dataPoints.count)
        let allPace = allSpeed > 0.1 ? 500.0 / allSpeed : 0
        let allStroke = dataPoints.map { $0.strokeRate }.reduce(0, +) / Double(dataPoints.count)
        let allWobble = dataPoints.map { $0.wobble }.reduce(0, +) / Double(dataPoints.count)
        let totalDist = dataPoints.map { $0.distanceM }.reduce(0, +)
        summaries.append(MinuteSummary(minute: 0, avgPace: allPace, avgStrokeRate: allStroke, avgWobble: allWobble, distanceM: totalDist))

        DispatchQueue.main.async {
            self.sessionSummary = summaries
            self.showingSummary = true
        }
    }

    // MARK: - CloudKit Upload

    // TODO: make the database upload more real time so that
    //    a coach can potentially monitor it

    private func uploadToCloudKit() {
        guard !pendingRecords.isEmpty else { return }
        let records = pendingRecords
        pendingRecords = []

        // CloudKit batch limit is 400 records per operation
        let batches = stride(from: 0, to: records.count, by: 400).map {
            Array(records[$0..<min($0 + 400, records.count)])
        }

        for batch in batches {
            let operation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    print("WOBBLE: CloudKit batch uploaded \(batch.count) records")
                case .failure(let error):
                    print("WOBBLE: CloudKit upload error: \(error)")
                }
            }
            cloudDB.add(operation)
        }
    }

    // MARK: - Stroke Rate

    // Time the gaps between recent stroke onsets and report 60 / (mean interval).
    // Continuous (unlike counting cycles in a fixed window, which quantizes the
    // rate) and robust to a varying rate (unlike autocorrelation). Onsets are
    // detected by hysteresis on the smoothed surge; the output filtered.
    private func computeStrokeRate() -> Double {
        let now = Double(strokeSamples) * 0.1
        strokeSamples += 1

        let n = smoothedSurgeBuffer.count
        guard n >= 1, let current = smoothedSurgeBuffer.last else { return emitStrokeRate(0) }

        // Mean/RMS over the trailing window set the onset threshold
        let mean = smoothedSurgeBuffer.reduce(0, +) / Double(n)
        let rms = sqrt(smoothedSurgeBuffer.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n))

        // Warm-up and idle gate
        guard now + 0.1 >= strokeMinSeconds, rms > strokeMinRMS else { return emitStrokeRate(0) }

        // Hysteresis onset detection: rising above +threshold after dropping below
        // -threshold marks a stroke. The threshold scales with RMS so weak-but-real
        // strokes are caught while small jitter is rejected.
        let centered = current - mean
        let threshold = strokeThresholdFraction * rms
        if !strokeHigh, centered > threshold {
            strokeHigh = true
            strokeOnsetTimes.append(now)
            if strokeOnsetTimes.count > strokesToAverage + 1 { strokeOnsetTimes.removeFirst() }
        } else if strokeHigh, centered < -threshold {
            strokeHigh = false
        }

        guard let last = strokeOnsetTimes.last, strokeOnsetTimes.count >= 2 else { return emitStrokeRate(0) }
        // No stroke for too long -> treat as stopped
        if now - last > strokeMaxGapSeconds { return emitStrokeRate(0) }

        let intervals = zip(strokeOnsetTimes.dropFirst(), strokeOnsetTimes).map { $0 - $1 }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0 else { return emitStrokeRate(0) }
        return emitStrokeRate(60.0 / avg)
    }

    // Exponential smoothing of the output rate. A zero (idle/stopped) resets the
    // smoother so the number drops promptly instead of decaying.
    private func emitStrokeRate(_ raw: Double) -> Double {
        if raw <= 0 {
            strokeSmoothedRate = 0
        } else if strokeSmoothedRate <= 0 {
            strokeSmoothedRate = raw   // seed on first stroke to avoid a slow ramp from 0
        } else {
            strokeSmoothedRate = strokeOutputSmoothing * raw + (1 - strokeOutputSmoothing) * strokeSmoothedRate
        }
        return strokeSmoothedRate
    }

    // Horizontal travel direction in the world frame (X = true north, Y = west).
    // Option A: GPS course when valid and moving. Option B: dominant axis of recent
    // horizontal acceleration. Falls back to the last known axis, or nil until one exists.
    // necessary to find this so that we only count accelleration in this direction
    private func forwardAxis(rawCourse: Double, speed: Double) -> (x: Double, y: Double)? {
        // Option A: GPS course (degrees clockwise from true north; -1 when invalid)
        if rawCourse >= 0, speed > minCourseSpeed {
            let rad = rawCourse * .pi / 180.0
            let axis = (x: cos(rad), y: -sin(rad))
            lastForwardAxis = axis
            axisSource = "A"
            return axis
        }
        // Option B: principal axis of horizontal acceleration variance
        if let axis = principalHorizontalAxis() {
            lastForwardAxis = axis
            axisSource = "B"
            return axis
        }
        axisSource = lastForwardAxis != nil ? "held" : "none"
        return lastForwardAxis
    }

    // Dominant axis of recent world-horizontal acceleration (the surge direction),
    // used when GPS course is unavailable. Sign is aligned to the previous axis so
    // the projected signal stays continuous (the eigenvector's sign is arbitrary).
    private func principalHorizontalAxis() -> (x: Double, y: Double)? {
        let n = horizontalAccelBuffer.count
        guard n >= pcaMinSamples else { return nil }
        let mx = horizontalAccelBuffer.reduce(0) { $0 + $1.x } / Double(n)
        let my = horizontalAccelBuffer.reduce(0) { $0 + $1.y } / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in horizontalAccelBuffer {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        // Require some directional energy before trusting an axis
        guard (sxx + syy) / Double(n) > minSurgeVariance else { return nil }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var axis = (x: cos(theta), y: sin(theta))
        if let last = lastForwardAxis, axis.x * last.x + axis.y * last.y < 0 {
            axis = (x: -axis.x, y: -axis.y)
        }
        return axis
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
        if isArmed { checkAutoStart(locations) }
    }

    private func checkAutoStart(_ locations: [CLLocation]) {
        for location in locations {
            // speed is -1 when invalid
            if location.speed >= autoStartSpeed {
                if autoStartFixCount == 0 { autoStartFirstFixTime = location.timestamp }
                autoStartFixCount += 1
            } else {
                autoStartFixCount = 0
                autoStartFirstFixTime = nil
            }
            if autoStartFixCount >= autoStartConsecutiveFixes {
                start(at: autoStartFirstFixTime ?? location.timestamp)
                return
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            if isRecording || isArmed { manager.startUpdatingLocation() }
        }
    }

    // MARK: - CSV Save

    // we save the data for analysis on the phone itself

    // TODO: figure out how to save the CSV to the iCloud files rather than the onDevice file folders
    private func saveCSV() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = formatter.string(from: startDate ?? Date())
        let filename = "wobble_\(dateStr).csv"

        let content = csvRows.joined(separator: "\n")

        let fileURL: URL
        var locationLabel: String

        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        fileURL = docsURL.appendingPathComponent(filename)
        locationLabel = "Saved: \(filename)"

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.lastSavedFilename = locationLabel
            }
        } catch {
            print("CSV save error: \(error)")
            DispatchQueue.main.async {
                self.lastSavedFilename = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
