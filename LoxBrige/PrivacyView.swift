import SwiftUI

/// Brief privacy notice that satisfies Apple App Store requirements for HealthKit apps
/// and informs EU users about how their data is processed.
struct PrivacyView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Text("LoxBridge is designed to keep you in control of your personal data. Here's exactly what the app does with it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            // MARK: Data collected
            Section("Data we access") {
                PrivacyRow(
                    icon: "heart.fill",
                    iconColor: .red,
                    title: "Health & workout data",
                    detail: "LoxBridge reads your workouts and GPS routes from the Apple Health app. This data stays on your device and is never shared with anyone other than Livelox, and only when you initiate an upload."
                )
                PrivacyRow(
                    icon: "location.fill",
                    iconColor: .blue,
                    title: "Location data",
                    detail: "GPS coordinates are read from your workout route (stored in the Health app by your Apple Watch or iPhone). LoxBridge also looks up a place name (e.g. Skatås, Göteborg) for each route using Apple's on-device geocoding service."
                )
            }

            // MARK: Third-party sharing
            Section("Data shared with third parties") {
                PrivacyRow(
                    icon: "arrow.up.to.line.circle.fill",
                    iconColor: .accentColor,
                    title: "Livelox",
                    detail: "When you upload a route, LoxBridge sends the GPX file (GPS track with timestamps) to Livelox. Livelox is a Swedish company that provides orienteering route analysis. By uploading, you agree to Livelox's own terms and privacy policy."
                )
                Button("Livelox User Agreement") {
                    if let url = URL(string: "https://www.livelox.com/UserAgreement") {
                        openURL(url)
                    }
                }
                .font(.subheadline)
            }

            // MARK: What we do NOT do
            Section("What we do NOT do") {
                PrivacyRow(
                    icon: "xmark.shield.fill",
                    iconColor: .green,
                    title: "No advertising or analytics",
                    detail: "LoxBridge contains no advertising SDKs, no analytics trackers, and no crash reporting services that transmit your data to third parties."
                )
                PrivacyRow(
                    icon: "person.slash.fill",
                    iconColor: .green,
                    title: "No accounts required",
                    detail: "LoxBridge itself has no accounts and stores no personal information on any server. All settings and route history are stored locally on your device."
                )
                PrivacyRow(
                    icon: "icloud.slash.fill",
                    iconColor: .green,
                    title: "No background data collection",
                    detail: "LoxBridge only reads health data in direct response to a completed workout notification. It does not run persistent background processes that sample your location or health."
                )
            }

            // MARK: User rights
            Section("Your rights & controls") {
                PrivacyRow(
                    icon: "hand.raised.fill",
                    iconColor: .orange,
                    title: "Revoke HealthKit access",
                    detail: "Go to Settings → Health → Apps → LoxBridge at any time to remove access. LoxBridge will stop detecting new workouts immediately."
                )
                PrivacyRow(
                    icon: "trash.fill",
                    iconColor: .orange,
                    title: "Delete local data",
                    detail: "Routes stored on this device can be deleted from the Routes tab. Deleting the app removes all local data. Routes already uploaded to Livelox must be removed directly on the Livelox website."
                )
                PrivacyRow(
                    icon: "envelope.fill",
                    iconColor: .secondary,
                    title: "Questions or requests",
                    detail: "For any privacy-related questions or data deletion requests regarding data on Livelox, contact Livelox support directly."
                )
            }

            // MARK: Legal basis (GDPR)
            Section("Legal basis (GDPR)") {
                Text("If you are in the European Union or European Economic Area, LoxBridge processes your health and location data on the basis of your **explicit consent**, which you grant by authorizing HealthKit access and by initiating each upload to Livelox. You may withdraw consent at any time using the controls above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy Notice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helper view

private struct PrivacyRow: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        PrivacyView()
    }
}
