import SwiftUI

/// Simple workout recording view: Start → active (time + distance + Pause/Stop) → summary.
/// When the workout ends it is saved to HealthKit; the iPhone picks it up automatically.
struct WorkoutView: View {
    @StateObject private var wm = WorkoutManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch wm.state {
            case .idle:     idleView
            case .active,
                 .paused:   activeView
            case .finished: finishedView
            }
        }
        .onDisappear {
            // Safety: if user swipes back during workout, stop it.
            if wm.state == .active || wm.state == .paused {
                Task { await wm.stop() }
            }
            if wm.state == .finished { wm.reset() }
        }
        .alert("Error", isPresented: Binding(
            get:  { wm.errorMessage != nil },
            set:  { if !$0 { wm.errorMessage = nil } }
        )) {
            Button("OK") { wm.errorMessage = nil }
        } message: {
            Text(wm.errorMessage ?? "")
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Outdoor Run")
                .font(.headline)
            Button("Start") {
                Task { await wm.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    // MARK: - Active / Paused

    private var activeView: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            Text(formattedTime)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .opacity(wm.state == .paused ? 0.45 : 1.0)

            Text(formattedDistance)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(wm.state == .paused ? 0.45 : 1.0)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                // Pause / Resume
                Button {
                    wm.togglePause()
                } label: {
                    Image(systemName: wm.state == .active ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                // Stop
                Button {
                    Task { await wm.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal)
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text(formattedDistance)
                .font(.title3.bold())

            Text(formattedTime)
                .foregroundStyle(.secondary)

            Text("Uploading to Livelox…")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Done") {
                wm.reset()
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Formatters

    private var formattedTime: String {
        let h = wm.elapsedSeconds / 3600
        let m = (wm.elapsedSeconds % 3600) / 60
        let s = wm.elapsedSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var formattedDistance: String {
        wm.distanceMeters >= 1000
            ? String(format: "%.2f km", wm.distanceMeters / 1000)
            : String(format: "%.0f m",  wm.distanceMeters)
    }
}
