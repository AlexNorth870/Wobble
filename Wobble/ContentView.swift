import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = DataRecorder()
    @State private var elapsedTime: TimeInterval = 0
    @State private var displayTimer: Timer?
    @State private var showingAbout = false
    @State private var previousBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        VStack(spacing: 48) {
            HStack {
                Spacer()
                Button(action: { showingAbout = true }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .padding(.trailing)
            }
            .padding(.top)

            Spacer()

            Text(timeString(from: elapsedTime))
                .font(.system(size: 72, weight: .thin, design: .monospaced))
                .foregroundColor(.primary)

            if recorder.isRecording && elapsedTime >= 10 {
                VStack(spacing: 4) {
                    Text(paceString(from: recorder.currentSpeedMps))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("min/500m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if recorder.isRecording {
                Text("--:--")
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if recorder.isRecording {
                VStack(spacing: 4) {
                    Text(String(format: "%.0f°", recorder.wobbleFactor))
                        .font(.system(size: 56, weight: .light, design: .monospaced))
                        .foregroundColor(.red)
                    Text("Wobble Factor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if recorder.isRecording {
                VStack(spacing: 4) {
                    Text(recorder.strokeRate > 0 ? String(format: "%.1f", recorder.strokeRate) : "---")
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("Stroke Rate (spm)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

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
        .sheet(isPresented: $showingAbout) {
            AboutView(shortUserID: recorder.shortUserID, appVersion: appVersion)
        }
        .sheet(isPresented: $recorder.showingSummary) {
            SessionSummaryView(summary: recorder.sessionSummary) {
                recorder.showingSummary = false
            }
        }
        .onChange(of: recorder.isRecording) { recording in
            if recording {
                previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0
            } else {
                UIScreen.main.brightness = previousBrightness
            }
        }
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

    private func paceString(from speedMps: Double) -> String {
        guard speedMps > 0.1 else { return "--:--" }
        let secondsPer500m = 500.0 / speedMps
        let minutes = Int(secondsPer500m) / 60
        let seconds = Int(secondsPer500m) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
