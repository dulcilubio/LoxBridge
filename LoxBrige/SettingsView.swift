import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.openURL) private var openURL
    @AppStorage("minWorkoutDistanceKm")      private var minWorkoutDistanceKm:      Double = 0
    @AppStorage("minWorkoutDurationSecs")    private var minWorkoutDurationSecs:    Double = 0
    @AppStorage("askBeforeUpload")           private var askBeforeUpload:           Bool   = false
    @AppStorage("notifyOnUploadStarted")     private var notifyOnUploadStarted:     Bool   = false
    @AppStorage("notifyOnUploadFailed")   private var notifyOnUploadFailed:   Bool = false
    @AppStorage("notifyOnUploadComplete") private var notifyOnUploadComplete: Bool = true

    @State private var versionTapCount = 0
    @State private var showFireworks = false
    @State private var notificationsAuthorized: Bool = true
    @State private var showAppleSourceWarning = false
    @State private var pendingDisableBundleID: String? = nil

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

                    // Notification row: only appears when notifications are disabled.
                    if !notificationsAuthorized {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bell.slash.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Notifications disabled")
                                        .foregroundStyle(.primary)
                                    Text("Tap to enable in iOS Settings — otherwise you won't be notified when a route is on Livelox")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                    Stepper(value: $minWorkoutDurationSecs, in: 0...300, step: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Minimum duration")
                            Text(
                                minWorkoutDurationSecs > 0
                                    ? String(format: String(localized: "Activities shorter than %d s will not be sent to Livelox"), Int(minWorkoutDurationSecs))
                                    : String(localized: "All activities will be sent to Livelox regardless of duration")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Ask before uploading", isOn: $askBeforeUpload)
                } header: {
                    Text("Filters and Upload")
                } footer: {
                    Text("Activities shorter or briefer than these thresholds will not be sent to Livelox.")
                        .font(.caption)
                }

                // MARK: Recording Apps
                Section {
                    LabeledContent("LoxBridge Watch") {
                        Text("Always enabled")
                            .foregroundStyle(.secondary)
                    }
                    let sources = WorkoutSourceRegistry.shared.nonBuiltInSources
                    if sources.isEmpty {
                        Text("No additional apps discovered yet. Apps that have recorded a GPS route in Health appear here automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources) { source in
                            let bundleID = source.bundleID
                            let isApple = bundleID.hasPrefix("com.apple.")
                            Toggle(source.displayName, isOn: Binding(
                                get: { WorkoutSourceRegistry.shared.isEnabled(bundleID: bundleID) },
                                set: { newValue in
                                    if !newValue && isApple {
                                        pendingDisableBundleID = bundleID
                                        showAppleSourceWarning = true
                                    } else {
                                        WorkoutSourceRegistry.shared.setEnabled(bundleID: bundleID, enabled: newValue)
                                    }
                                }
                            ))
                        }
                    }
                } header: {
                    Text("Recording Apps")
                } footer: {
                    Text("Apps that have delivered a GPS route to LoxBridge appear here automatically. Only apps with GPS route support are shown.")
                        .font(.caption)
                }
                .confirmationDialog(
                    "Disable Apple Fitness routes?",
                    isPresented: $showAppleSourceWarning,
                    titleVisibility: .visible
                ) {
                    Button("Disable", role: .destructive) {
                        if let id = pendingDisableBundleID {
                            WorkoutSourceRegistry.shared.setEnabled(bundleID: id, enabled: false)
                        }
                        pendingDisableBundleID = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDisableBundleID = nil
                    }
                } message: {
                    Text("Workouts recorded with the Apple Workout app will no longer be uploaded to Livelox.")
                }

                // MARK: Troubleshooting
                Section {
                    NavigationLink("Missing workouts?") {
                        WorkoutDiagnosticsView()
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("See which workouts LoxBridge can read from Health, why some are skipped, and import older ones.")
                        .font(.caption)
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
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsAuthorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
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

    /// "1.0 (42) · 19 Mar 2026 · a1b2c3d" — tap 10 times to trigger the fireworks easter egg.
    /// The git commit hash is injected into Info.plist at build time by the "Inject Git Commit"
    /// Run Script Build Phase; falls back to "–" if not present (e.g. simulator without a git repo).
    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let commit  = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String
        var s = "\(version) (\(build))"
        if let date = executableBuildDate { s += " · \(date)" }
        if let c = commit, !c.isEmpty      { s += " · \(c)" }
        return s
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
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation { showFireworks = false }
            }
        }
    }
}

// MARK: - Fireworks easter egg

/// Full-screen fireworks: multiple CAEmitterLayer bursts at random sky positions,
/// mixed particle shapes, haptic pulses, and a brief flash overlay.
private struct FireworksView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        // Brief white flash to punctuate the first explosion
        let flash = UIView(frame: view.bounds)
        flash.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        flash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(flash)
        UIView.animate(withDuration: 0.25, delay: 0.05) { flash.alpha = 0 }
            completion: { _ in flash.removeFromSuperview() }

        // Schedule 7 staggered explosion bursts across the screen
        let delays: [Double] = [0, 0.25, 0.55, 0.85, 1.15, 1.5, 1.9]
        for (i, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !view.bounds.isEmpty else { return }
                addBurst(to: view, index: i)
                if i < 3 {
                    UIImpactFeedbackGenerator(style: i == 0 ? .heavy : .medium)
                        .impactOccurred()
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Reposition emitters when the view is finally laid out (bounds were .zero at makeUIView)
        guard !uiView.bounds.isEmpty else { return }
        for layer in uiView.layer.sublayers ?? [] {
            guard let emitter = layer as? CAEmitterLayer,
                  emitter.emitterPosition == .zero else { continue }
            emitter.frame = uiView.bounds
            emitter.emitterPosition = randomBurstPosition(in: uiView.bounds)
        }
    }

    // MARK: - Burst builder

    private func addBurst(to view: UIView, index: Int) {
        let bounds = view.bounds
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = randomBurstPosition(in: bounds)
        emitter.emitterShape = .point
        emitter.renderMode = .additive

        let palette: [[UIColor]] = [
            [.systemRed,    .systemOrange, .systemYellow],
            [.systemGreen,  .systemTeal,   .white],
            [.systemBlue,   .systemPurple, .systemPink],
            [.systemYellow, .systemOrange, .white],
            [.systemPink,   .systemRed,    .white],
            [.systemCyan,   .systemGreen,  .systemYellow],
            [.systemPurple, .systemPink,   .white],
        ]
        let colors = palette[index % palette.count]
        emitter.emitterCells = colors.flatMap { color in
            [makeConfettiCell(color: color),
             makeSparkCell(color: color),
             makeStreamerCell(color: color)]
        }
        view.layer.addSublayer(emitter)

        // Burst: emit hard for 0.3 s, then let particles coast and fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            emitter.birthRate = 0
        }
    }

    private func randomBurstPosition(in bounds: CGRect) -> CGPoint {
        let x = CGFloat.random(in: bounds.width * 0.15 ... bounds.width * 0.85)
        let y = CGFloat.random(in: bounds.height * 0.08 ... bounds.height * 0.55)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Particle shapes

    /// Round confetti dot
    private func makeConfettiCell(color: UIColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents      = circleImage(color: color, size: 12)
        cell.birthRate     = 60
        cell.lifetime      = 3.2
        cell.lifetimeRange = 0.8
        cell.velocity      = 320
        cell.velocityRange = 180
        cell.emissionLongitude = 0
        cell.emissionRange     = .pi * 2   // omnidirectional burst
        cell.spin              = 5
        cell.spinRange         = 10
        cell.scale             = 0.25
        cell.scaleRange        = 0.15
        cell.scaleSpeed        = -0.03
        cell.alphaSpeed        = -0.2
        cell.yAcceleration     = 180
        return cell
    }

    /// Long thin streamer / ribbon
    private func makeStreamerCell(color: UIColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents      = streamerImage(color: color)
        cell.birthRate     = 30
        cell.lifetime      = 3.5
        cell.lifetimeRange = 1.0
        cell.velocity      = 260
        cell.velocityRange = 140
        cell.emissionLongitude = 0
        cell.emissionRange     = .pi * 2
        cell.spin              = 8
        cell.spinRange         = 16
        cell.scale             = 0.4
        cell.scaleRange        = 0.2
        cell.scaleSpeed        = -0.02
        cell.alphaSpeed        = -0.18
        cell.yAcceleration     = 200
        return cell
    }

    /// Bright spark/star that flashes
    private func makeSparkCell(color: UIColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents      = starImage(color: color)
        cell.birthRate     = 20
        cell.lifetime      = 1.8
        cell.lifetimeRange = 0.6
        cell.velocity      = 480
        cell.velocityRange = 220
        cell.emissionLongitude = 0
        cell.emissionRange     = .pi * 2
        cell.spin              = 3
        cell.spinRange         = 6
        cell.scale             = 0.15
        cell.scaleRange        = 0.08
        cell.scaleSpeed        = -0.05
        cell.alphaSpeed        = -0.5
        cell.yAcceleration     = 120
        return cell
    }

    // MARK: - Image generators

    private func circleImage(color: UIColor, size: CGFloat = 12) -> CGImage? {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: s))
        }.cgImage
    }

    private func streamerImage(color: UIColor) -> CGImage? {
        let s = CGSize(width: 4, height: 16)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: s),
                         cornerRadius: 2).fill()
        }.cgImage
    }

    private func starImage(color: UIColor) -> CGImage? {
        let s = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = CGPoint(x: 8, y: 8)
            let path = UIBezierPath()
            for i in 0 ..< 4 {
                let outer = CGFloat(i) * .pi / 2
                let inner = outer + .pi / 4
                let oR: CGFloat = 8, iR: CGFloat = 3
                let op = CGPoint(x: c.x + oR * cos(outer), y: c.y + oR * sin(outer))
                let ip = CGPoint(x: c.x + iR * cos(inner), y: c.y + iR * sin(inner))
                i == 0 ? path.move(to: op) : path.addLine(to: op)
                path.addLine(to: ip)
            }
            path.close()
            color.setFill(); path.fill()
        }.cgImage
    }
}

#Preview {
    SettingsView(model: AppViewModel())
}
