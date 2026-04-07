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
            Text("Orienteering!")
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
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            Text(formattedTime)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .opacity(wm.state == .paused ? 0.45 : 1.0)

            Text(formattedDistance)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(wm.state == .paused ? 0.45 : 1.0)

            Text(formattedPace)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(wm.state == .paused ? 0.45 : 1.0)

            Spacer(minLength: 0)

            if wm.state == .active {
                // Single orange pause button while running
                Button { wm.togglePause() } label: {
                    Image(systemName: "pause.fill")
                        .font(.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                // Two side-by-side buttons while paused: resume (green) | stop (red)
                HStack(spacing: 10) {
                    Button { wm.togglePause() } label: {
                        Image(systemName: "play.fill")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button { Task { await wm.stop() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)

            Text(formattedDistance)
                .font(.title3.bold())

            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(formattedTime)
                        .font(.caption.monospacedDigit())
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(spacing: 2) {
                    Text(formattedPace)
                        .font(.caption.monospacedDigit())
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)

            Button {
                wm.reset()
                dismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.horizontal)
    }

    // MARK: - Formatters

    private var formattedPace: String {
        guard wm.distanceMeters > 50 else { return "--:-- /km" }
        let secsPerKm = Double(wm.elapsedSeconds) / (wm.distanceMeters / 1000.0)
        let m = Int(secsPerKm) / 60
        let s = Int(secsPerKm) % 60
        return String(format: "%d:%02d /km", m, s)
    }

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
