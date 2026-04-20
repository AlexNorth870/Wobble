import SwiftUI

struct AboutView: View {
    let shortUserID: String
    let appVersion: String

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Mission
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About Wobble")
                            .font(.title2).bold()
                        Text("Crew is about power and stability. In the spirit of \"You can't improve what you don't measure\", this app measures how the shell wobbles during training with the Wobble Factor.")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Key facts
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(icon: "checkmark.circle", text: "Wobble is always free")
                        InfoRow(icon: "flask", text: "This is a research project")
                        InfoRow(icon: "person.slash", text: "No personally identifiable data is collected")
                        InfoRow(icon: "location", text: "GPS is used to determine speed and location")
                        InfoRow(icon: "water.waves", text: "Location is used to study the effect of different bodies of water on the model")
                        InfoRow(icon: "doc.text", text: "A CSV file is generated on your iPhone with your session data")
                        InfoRow(icon: "icloud.and.arrow.up", text: "Anonymous data is uploaded to a research database to improve the model")
                    }

                    Divider()

                    // Website
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Website")
                            .font(.headline)
                        Link("WobbleRowing.com", destination: URL(string: "https://www.wobblerowing.com")!)
                            .foregroundColor(.blue)
                    }

                    Divider()

                    // Device info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Device")
                            .font(.headline)
                        HStack {
                            Text("Rower ID:")
                                .foregroundColor(.secondary)
                            Text(shortUserID)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                        }
                        Text("This 8-character ID is a one-way hash — it cannot be traced back to you personally.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Version
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version")
                            .font(.headline)
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("© 2026 Alex North")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(text)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
