import SwiftUI

struct SessionSummaryView: View {
    let summary: [MinuteSummary]
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                // Header row
                HStack {
                    Text("Min")
                        .frame(width: 40, alignment: .leading)
                    Spacer()
                    Text("Pace")
                        .frame(width: 62, alignment: .trailing)
                    Spacer()
                    Text("Stroke")
                        .frame(width: 58, alignment: .trailing)
                    Spacer()
                    Text("Wobble")
                        .frame(width: 58, alignment: .trailing)
                    Spacer()
                    Text("Dist")
                        .frame(width: 58, alignment: .trailing)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Per-minute rows + session total
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(summary, id: \.minute) { row in
                            let isTotal = row.minute == 0
                            HStack {
                                Text(isTotal ? "Tot" : "\(row.minute)")
                                    .frame(width: 40, alignment: .leading)
                                    .bold(isTotal)
                                Spacer()
                                Text(paceString(row.avgPace))
                                    .frame(width: 62, alignment: .trailing)
                                    .bold(isTotal)
                                Spacer()
                                Text(row.avgStrokeRate > 0 ? String(format: "%.1f", row.avgStrokeRate) : "---")
                                    .frame(width: 58, alignment: .trailing)
                                    .bold(isTotal)
                                Spacer()
                                Text(String(format: "%.1f°", row.avgWobble))
                                    .frame(width: 58, alignment: .trailing)
                                    .bold(isTotal)
                                Spacer()
                                Text(distanceString(row.distanceM))
                                    .frame(width: 58, alignment: .trailing)
                                    .bold(isTotal)
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(isTotal ? Color.secondary.opacity(0.15) : Color.clear)

                            if !isTotal { Divider() }
                        }
                    }
                }
            }
            .navigationTitle("Session Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func paceString(_ secondsPer500m: Double) -> String {
        guard secondsPer500m > 0 else { return "--:--" }
        let minutes = Int(secondsPer500m) / 60
        let seconds = Int(secondsPer500m) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func distanceString(_ meters: Double) -> String {
        guard meters > 0 else { return "---" }
        return "\(Int(meters.rounded()))m"
    }
}
