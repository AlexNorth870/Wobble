import Foundation
import CoreLocation
import CoreMotion

class DataRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isRecording = false
    @Published var lastSavedFilename: String?
    @Published var currentSpeedMps: Double = 0

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let isoFormatter = ISO8601DateFormatter()

    private var startDate: Date?
    private var recordingTimer: Timer?
    private var csvRows: [String] = []
    private var currentLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestWhenInUseAuthorization()
    }

    func start() {
        startDate = Date()
        lastSavedFilename = nil
        csvRows = []
        csvRows.append(
            "stopwatch_time_s," +
            "timestamp," +
            "latitude_deg," +
            "longitude_deg," +
            "altitude_m," +
            "speed_mps," +
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
            "rotation_rate_z_rads"
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
        saveCSV()
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

        let row = String(
            format: "%.3f,%@,%.8f,%.8f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
            elapsed, timestamp,
            lat, lon, alt, speed, course,
            pitch, roll, yaw,
            ax, ay, az,
            gravX, gravY, gravZ,
            gx, gy, gz
        )
        csvRows.append(row)
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
