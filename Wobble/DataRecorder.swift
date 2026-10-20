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
    private var rotationMagnitudeBuffer: [Double] = []   // |roll rate| about the travel direction (rad/s)
    private var lastCourseAxis: (x: Double, y: Double)?  // GPS travel direction for the wobble roll axis
    private let wobbleBufferSize = 100
    // Stroke rate via the dominant rhythm of pitch, gravity-z and GPS speed over a
    // trailing window (each moves once per stroke). Surge is only used for the idle
    // gate: it often has two bumps per stroke, which doubled the reported rate.
    // Mirrors ReplayTools `FusedAnalyzer`; keep the two in step.
    private var rawSurgeBuffer: [Double] = []                         // recent raw surge, for smoothing
    private var smoothedSurgeBuffer: [Double] = []                    // trailing window of smoothed surge (idle gate RMS)
    private var strokePitchBuffer: [Double] = []                      // trailing window of pitch (rad)
    private var strokeGravityZBuffer: [Double] = []                   // trailing window of gravity z (g)
    private var strokeSpeedBuffer: [Double] = []                      // trailing window of GPS speed (m/s)
    private var strokeIdleSpeedBuffer: [Double] = []                  // last 6 s of GPS speed, for the idle gate
    private var strokeSamples = 0                                     // sample counter, paces the spectrum refresh
    private var strokeCurrentRate = 0.0                               // rate held between refreshes (spm)
    private var horizontalAccelBuffer: [(x: Double, y: Double)] = []  // world-horizontal accel, for the fallback axis
    private var lastForwardAxis: (x: Double, y: Double)?              // last known travel direction (world frame)
    private var axisSource: String = "none"                          // debug: which axis produced the last surge (A/B/held/none)
    private let axisBufferSize = 100      // 10 s of world-horizontal accel for the PCA fallback axis
    private let strokeSmoothingWindow = 10 // trailing surge moving average (~1 s) to cut jitter
    private let strokeIdleWindowSize = 60  // 6 s at 0.1 s: smoothed-surge window for the idle gate
    private let strokeMinRMS = 0.005      // below this surge RMS the boat is treated as at rest (report 0)
    private let strokeMinSpeed = 0.5      // m/s: below this mean speed the boat is at rest (phone handled at the dock)
    private let strokeWindowSize = 150     // 15 s at 0.1 s: window whose spectrum is analysed
    private let strokeMinSamples = 100     // 10 s of data before reporting a rate
    private let strokeUpdateEvery = 10     // refresh the spectrum once a second
    private let strokeMinSPM = 12.0       // stroke-rate search range and resolution (spm)
    private let strokeMaxSPM = 60.0
    private let strokeGridStepSPM = 0.5
    private let strokeMaxSpeedSPM = 29.0  // 1 Hz GPS speed can't resolve faster rates
    private let strokeHalfRatio = 0.3     // power at half the peak >= this fraction -> peak is a harmonic
    private let strokeHalfToleranceSPM = 1.0
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
        strokePitchBuffer = []
        strokeGravityZBuffer = []
        strokeSpeedBuffer = []
        strokeIdleSpeedBuffer = []
        strokeSamples = 0
        strokeCurrentRate = 0
        horizontalAccelBuffer = []
        lastForwardAxis = nil
        lastCourseAxis = nil
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
        strokePitchBuffer = []
        strokeGravityZBuffer = []
        strokeSpeedBuffer = []
        strokeIdleSpeedBuffer = []
        strokeSamples = 0
        strokeCurrentRate = 0
        horizontalAccelBuffer = []
        lastForwardAxis = nil
        lastCourseAxis = nil
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
        // horizontal rotation rate in the world frame, for the wobble roll axis
        var worldRotX: Double = 0, worldRotY: Double = 0

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
            // Rotate device-frame user acceleration and rotation rate into the world
            // frame. CMRotationMatrix maps world -> device, so device -> world uses
            // its transpose (column-wise products below).
            let m = motion.attitude.rotationMatrix
            worldAccelX = m.m11 * ax + m.m21 * ay + m.m31 * az
            worldAccelY = m.m12 * ax + m.m22 * ay + m.m32 * az
            worldRotX = m.m11 * gx + m.m21 * gy + m.m31 * gz
            worldRotY = m.m12 * gx + m.m22 * gy + m.m32 * gz
        }

        let pace = speed > 0.1 ? (500.0 / speed) / 60.0 : 0.0

        // Accumulate distance: velocity × sample interval (0.1 s)
        let sampleDistance = speed * 0.1
        distanceTravelled += sampleDistance

        // Surge (forward acceleration), for the stroke-rate idle gate and the log.
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
        // Smooth surge with a trailing moving average and keep 6 s of it for the
        // idle gate; keep 15 s of pitch, gravity z and speed for the stroke rhythm.
        rawSurgeBuffer.append(surge)
        if rawSurgeBuffer.count > strokeSmoothingWindow {
            rawSurgeBuffer.removeFirst()
        }
        let smoothedSurge = rawSurgeBuffer.reduce(0, +) / Double(rawSurgeBuffer.count)
        smoothedSurgeBuffer.append(smoothedSurge)
        if smoothedSurgeBuffer.count > strokeIdleWindowSize {
            smoothedSurgeBuffer.removeFirst()
        }
        strokePitchBuffer.append(pitch)
        strokeGravityZBuffer.append(gravZ)
        strokeSpeedBuffer.append(speed)
        strokeIdleSpeedBuffer.append(speed)
        if strokeIdleSpeedBuffer.count > strokeIdleWindowSize {
            strokeIdleSpeedBuffer.removeFirst()
        }
        if strokePitchBuffer.count > strokeWindowSize {
            strokePitchBuffer.removeFirst()
            strokeGravityZBuffer.removeFirst()
            strokeSpeedBuffer.removeFirst()
        }
        let currentStrokeRate = computeStrokeRate()
        DispatchQueue.main.async { self.strokeRate = currentStrokeRate }

        // Wobble factor: rolling 10s average of the boat's roll rate, i.e. rotation
        // about the travel direction (side-to-side rocking). Pitch from the stroke
        // cycle and yaw from steering are excluded. Until GPS gives a course, fall
        // back to all horizontal rotation (still excludes yaw).
        if rawCourse >= 0, speed > minCourseSpeed {
            let rad = rawCourse * .pi / 180.0
            lastCourseAxis = (x: cos(rad), y: -sin(rad))
        }
        let rollRate: Double
        if let axis = lastCourseAxis {
            rollRate = abs(worldRotX * axis.x + worldRotY * axis.y)
        } else {
            rollRate = sqrt(worldRotX * worldRotX + worldRotY * worldRotY)
        }
        rotationMagnitudeBuffer.append(rollRate)
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

    // Find the dominant stroke rhythm in the last 15 s of pitch, gravity z and GPS
    // speed, refreshed once a second. Matches ReplayTools `FusedAnalyzer`.
    private func computeStrokeRate() -> Double {
        strokeSamples += 1

        // Idle gate on smoothed surge and GPS speed over the last 6 s
        let n = Double(smoothedSurgeBuffer.count)
        guard n >= 1, !strokeIdleSpeedBuffer.isEmpty else { return 0 }
        let mean = smoothedSurgeBuffer.reduce(0, +) / n
        let rms = sqrt(smoothedSurgeBuffer.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n)
        let meanSpeed = strokeIdleSpeedBuffer.reduce(0, +) / Double(strokeIdleSpeedBuffer.count)

        // At rest: start the window afresh so the next piece isn't averaged with the paddle before it
        guard rms > strokeMinRMS, meanSpeed > strokeMinSpeed else {
            strokePitchBuffer = []
            strokeGravityZBuffer = []
            strokeSpeedBuffer = []
            strokeCurrentRate = 0
            return 0
        }
        // Warm-up
        guard strokePitchBuffer.count >= strokeMinSamples else {
            strokeCurrentRate = 0
            return 0
        }
        if strokeCurrentRate == 0 || strokeSamples % strokeUpdateEvery == 0 {
            strokeCurrentRate = fusedStrokeRate()
        }
        return strokeCurrentRate
    }

    // Each signal's power spectrum over the stroke-rate grid is normalized to sum
    // to 1 so they vote equally; the peak of the summed votes is the stroke rate.
    // Surge is left out because its two bumps per stroke vote for double the rate.
    private func fusedStrokeRate() -> Double {
        let grid = Array(stride(from: strokeMinSPM, through: strokeMaxSPM, by: strokeGridStepSPM))
        var total = [Double](repeating: 0, count: grid.count)

        func addVote(_ signal: [Double], maxSPM: Double) {
            let n = signal.count
            guard n >= 2 else { return }
            // Remove the straight-line trend (slow drift in heading, trim or speed would
            // otherwise leak into the lowest rates), then apply a Hann taper to reduce
            // leakage from the window edges into neighbouring rates
            let tMean = Double(n - 1) / 2
            let mean = signal.reduce(0, +) / Double(n)
            var sxy = 0.0, sxx = 0.0
            for (k, v) in signal.enumerated() {
                sxy += (Double(k) - tMean) * (v - mean)
                sxx += (Double(k) - tMean) * (Double(k) - tMean)
            }
            let slope = sxy / sxx
            let x = signal.enumerated().map { k, v in
                (v - mean - slope * (Double(k) - tMean)) * (0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(n - 1)))
            }
            let power = grid.map { spm -> Double in
                let w = 2 * .pi * spm / 60.0 * 0.1
                var re = 0.0, im = 0.0
                for (k, v) in x.enumerated() {
                    re += v * cos(w * Double(k))
                    im -= v * sin(w * Double(k))
                }
                return re * re + im * im
            }
            let sum = power.reduce(0, +)
            guard sum > 0 else { return }
            for i in grid.indices where grid[i] <= maxSPM {
                total[i] += power[i] / sum
            }
        }

        addVote(strokePitchBuffer, maxSPM: strokeMaxSPM)
        addVote(strokeGravityZBuffer, maxSPM: strokeMaxSPM)
        addVote(strokeSpeedBuffer, maxSPM: strokeMaxSpeedSPM)

        // A peak at the bottom of the range is slow drift, not a stroke rhythm
        guard let peak = total.indices.max(by: { total[$0] < total[$1] }), total[peak] > 0, peak > 0 else { return 0 }
        var rate = grid[peak]

        // A strong component at half the peak means the peak is the second harmonic
        let half = rate / 2
        if half >= strokeMinSPM {
            let halfPower = grid.indices
                .filter { abs(grid[$0] - half) <= strokeHalfToleranceSPM }
                .map { total[$0] }
                .max() ?? 0
            if halfPower >= strokeHalfRatio * total[peak] { rate = half }
        }
        return rate
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
