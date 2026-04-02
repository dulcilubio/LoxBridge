import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.openURL) private var openURL
    @AppStorage("minWorkoutDistanceKm")   private var minWorkoutDistanceKm:   Double = 0
    @AppStorage("notifyOnUploadStarted")  private var notifyOnUploadStarted:  Bool = false
    @AppStorage("notifyOnUploadFailed")   private var notifyOnUploadFailed:   Bool = false
    @AppStorage("notifyOnUploadComplete") private var notifyOnUploadComplete: Bool = true

    @State private var versionTapCount = 0
    @State private var showFireworks = false

    private var liveloxConnected: Bool { model.liveloxStatus == "Connected" }
    private var healthKitOK: Bool { model.healthKitStatus == "Authorized" }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Status
                Section("Status") {
                    // HealthKit row: only appears when access has been removed or denied.
                    if !healthKitOK {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            LabeledContent("HealthKit", value: model.healthKitStatus)
                        }
                    }

                    // Single Livelox row — combines connection state and account name.
                    LabeledContent("Livelox") {
                        Text(liveloxConnected
                             ? String(format: String(localized: "Connected to %@"), model.liveloxAccountName)
                             : String(localized: "Not connected"))
                            .foregroundStyle(liveloxConnected ? .primary : .secondary)
                    }
                }

                // MARK: Filters
                Section {
                    Stepper(value: $minWorkoutDistanceKm, in: 0...50, step: 0.1) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Minimum distance")
                            Text(
                                minWorkoutDistanceKm > 0
                                    ? String(format: String(localized: "Activities shorter than %.1f km will not be sent to Livelox"), minWorkoutDistanceKm)
                                    : String(localized: "All activities will be sent to Livelox regardless of distance")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Filters")
                }

                // MARK: Notifications
                Section("Notifications") {
                    Toggle("Uploading to Livelox", isOn: $notifyOnUploadStarted)
                    Toggle("Upload failed", isOn: $notifyOnUploadFailed)
                    Toggle("Route on Livelox", isOn: $notifyOnUploadComplete)
                }

                // MARK: Connections
                Section("Connections") {
                    // Opens the Health app → Sources tab where per-app permissions are managed.
                    Button("Open Health App Settings") {
                        if let url = URL(string: "x-apple-health://sources") {
                            UIApplication.shared.open(url)
                        }
                    }

                    if liveloxConnected {
                        Button("Disconnect Livelox", role: .destructive) {
                            Task { await model.disconnectLivelox() }
                        }
                    } else {
                        Button("Connect Livelox") {
                            Task { await model.connectLivelox() }
                        }
                    }
                }

                // MARK: App Info
                Section("App") {
                    // Tap 10 times to launch fireworks 🎆
                    LabeledContent("Version", value: appVersionString)
                        .contentShape(Rectangle())
                        .onTapGesture { handleVersionTap() }

                    NavigationLink("Privacy Notice") {
                        PrivacyView()
                    }
                }

                // MARK: Errors
                if let lastError = model.lastError {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(lastError)
                                .font(.caption)
                        }
                    }
                }

                // MARK: Developer (simulator only)
                #if targetEnvironment(simulator)
                Section {
                    Button("Simulate Workout") {
                        Task { await model.simulateWorkout() }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Injects a synthetic ~3 km GPS route through the full upload pipeline.")
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if showFireworks {
                    FireworksView()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Version string

    /// "1.0 (42) · 19 Mar 2026" — tap 10 times to trigger the fireworks easter egg.
    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        if let date = executableBuildDate {
            return "\(version) (\(build)) · \(date)"
        }
        return "\(version) (\(build))"
    }

    /// Modification date of the compiled binary — a reliable proxy for build date.
    private var executableBuildDate: String? {
        guard
            let path  = Bundle.main.executablePath,
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let date  = attrs[.modificationDate] as? Date
        else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    private func handleVersionTap() {
        versionTapCount += 1
        if versionTapCount >= 10 {
            versionTapCount = 0
            withAnimation { showFireworks = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showFireworks = false }
            }
        }
    }
}

// MARK: - Fireworks easter egg

/// CAEmitterLayer-based confetti burst rendered over the settings form.
private struct FireworksView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        let emitter = CAEmitterLayer()
        emitter.frame = view.bounds
        emitter.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.maxY)
        emitter.emitterShape = .point
        emitter.renderMode = .oldestLast

        let colors: [UIColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemBlue, .systemPurple,
            .systemPink, .white
        ]
        emitter.emitterCells = colors.map { makeCell(color: $0) }
        view.layer.addSublayer(emitter)

        // Emit for 1 s then let the existing particles drift and fade naturally.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            emitter.birthRate = 0
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private func makeCell(color: UIColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents      = circle(color: color)
        cell.birthRate     = 12
        cell.lifetime      = 2.8
        cell.lifetimeRange = 0.6
        cell.velocity      = 480
        cell.velocityRange = 200
        cell.emissionLongitude = -.pi / 2    // fire upward
        cell.emissionRange     = .pi * 0.75  // wide fan spread
        cell.spin              = 4
        cell.spinRange         = 8
        cell.scale             = 0.2
        cell.scaleRange        = 0.12
        cell.scaleSpeed        = -0.04
        cell.alphaSpeed        = -0.25
        cell.yAcceleration     = 220         // gravity pulls them back down
        return cell
    }

    private func circle(color: UIColor) -> CGImage? {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

#Preview {
    SettingsView(model: AppViewModel())
}
