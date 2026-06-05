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
    let shortUserID: String = {
        let raw = UserDefaults.standard.string(forKey: "wobble_user_uuid") ?? UUID().uuidString
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8).uppercased()
    }()

    // Track number — increments each time Start is pressed, persists across app restarts
    private(set) var trackNumber: Int = UserDefaults.standard.integer(forKey: "wobble_track_number")

    private var startDate: Date?
    private var recordingTimer: Timer?
    private var csvRows: [String] = []
    private var currentLocation: CLLocation?
    // 10 seconds at 0.1s intervals = 100 samples
    private var rotationMagnitudeBuffer: [Double] = []
    private let wobbleBufferSize = 100
    // Stroke rate autocorrelation
    private var accelMagnitudeBuffer: [Double] = []
    private let strokeBufferSize = 100
    private let minStrokeLag = 12  // 50 spm = 1.2s = 12 samples
    private let maxStrokeLag = 60  // 10 spm = 6.0s = 60 samples
    // Minimum normalized autocorrelation peak (0...1) required to trust a reading
    private let minStrokeConfidence = 0.15

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestWhenInUseAuthorization()
    }

    func start() {
        trackNumber += 1
        UserDefaults.standard.set(trackNumber, forKey: "wobble_track_number")
        startDate = Date()
        lastSavedFilename = nil
        csvRows = []
        rotationMagnitudeBuffer = []
        accelMagnitudeBuffer = []
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
            "distance_cumulative_m"
        )

        locationManager.startUpdatingLocation()

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.02
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        }

        isRecording = true

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordDataPoint()
            // Update speed display every second after 10s have elapsed
            let elapsed = Date().timeIntervalSince(self.startDate ?? Date())
            if elapsed >= 10, Int(elapsed * 10) % 10 == 0 {
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
        accelMagnitudeBuffer = []
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
        }

        let pace = speed > 0.1 ? (500.0 / speed) / 60.0 : 0.0

        // Accumulate distance: velocity × sample interval (0.1 s)
        let sampleDistance = speed * 0.1
        distanceTravelled += sampleDistance

        // Stroke rate via autocorrelation of user acceleration magnitude
        let accelMag = sqrt(ax * ax + ay * ay + az * az)
        accelMagnitudeBuffer.append(accelMag)
        if accelMagnitudeBuffer.count > strokeBufferSize {
            accelMagnitudeBuffer.removeFirst()
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
        let currentWobble = (avgMagnitudeRads * 180.0 / .pi).rounded()
        DispatchQueue.main.async { self.wobbleFactor = currentWobble }

        let row = "\(shortUserID),\(trackNumber)," + String(
            format: "%.3f,%@,%.8f,%.8f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.1f,%.2f",
            elapsed, timestamp,
            lat, lon, alt, speed, pace, course,
            pitch, roll, yaw,
            ax, ay, az,
            gravX, gravY, gravZ,
            gx, gy, gz,
            currentWobble,
            currentStrokeRate,
            distanceTravelled
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

    private func computeStrokeRate() -> Double {
        let n = accelMagnitudeBuffer.count
        guard n > maxStrokeLag else { return 0 }

        // Only calculate if the last 10 samples all exceed the activity threshold
        let recentSamples = accelMagnitudeBuffer.suffix(10)
        guard recentSamples.count == 10, recentSamples.allSatisfy({ $0 > 0.15 }) else { return 0 }

        // Subtract mean to center signal around zero
        let mean = accelMagnitudeBuffer.reduce(0, +) / Double(n)
        let centered = accelMagnitudeBuffer.map { $0 - mean }

        // Signal energy (lag-0 autocorrelation) used to normalize peaks into [-1, 1]
        let variance = centered.map { $0 * $0 }.reduce(0, +) / Double(n)
        guard variance > 0 else { return 0 }

        // Autocorrelation: find lag with highest normalized correlation in stroke rate range
        var bestCorr = -Double.infinity
        var bestLag = 0

        for lag in minStrokeLag...maxStrokeLag {
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
        guard bestLag > 0, bestCorr >= minStrokeConfidence else { return 0 }
        let periodSeconds = Double(bestLag) * 0.1
        return 60.0 / periodSeconds
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            if isRecording { manager.startUpdatingLocation() }
        }
    }

    // MARK: - CSV Save

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
