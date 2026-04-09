import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = DataRecorder()
    @State private var elapsedTime: TimeInterval = 0
    @State private var displayTimer: Timer?

    var body: some View {
        VStack(spacing: 48) {
            Spacer()

            Text(timeString(from: elapsedTime))
                .font(.system(size: 72, weight: .thin, design: .monospaced))
                .foregroundColor(.primary)

            Button(action: toggleRecording) {
                Text(recorder.isRecording ? "Stop" : "Start")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 140, height: 140)
                    .background(recorder.isRecording ? Color.red : Color.green)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }

            if let filename = recorder.lastSavedFilename {
                Text("Saved: \(filename)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Text(appVersion)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            displayTimer?.invalidate()
            displayTimer = nil
        } else {
            elapsedTime = 0
            recorder.start()
            displayTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                elapsedTime += 0.01
            }
        }
    }

    private func timeString(from interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        let hundredths = Int((interval * 100).truncatingRemainder(dividingBy: 100))
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}

#Preview {
    ContentView()
}
