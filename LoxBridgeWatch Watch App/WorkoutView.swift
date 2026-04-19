import SwiftUI
import CoreLocation

/// Simple workout recording view: Start → active (time + distance + Pause/Stop) → summary.
/// When the workout ends it is saved to HealthKit; the iPhone picks it up automatically.
struct WorkoutView: View {
    @StateObject private var wm = WorkoutManager.shared
    @StateObject private var sessionMgr = WatchSessionManager.shared
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
        ZStack(alignment: .topTrailing) {
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

            // GPS accuracy indicator — icon only, no text.
            // Gray = no fix, yellow = coarse, green = good (< 20 m).
            Image(systemName: gpsIcon(wm.currentGPSAccuracy))
                .font(.caption2)
                .foregroundStyle(gpsColor(wm.currentGPSAccuracy))
                .padding(6)
        }
    }

    // MARK: - Active / Paused

    private var activeView: some View {
        ZStack(alignment: .topTrailing) {
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
                // Hold-to-pause: fill animation left → right over 0.6 s.
                // A quick accidental tap does nothing — must be held deliberately.
                HoldToActivateButton(icon: "pause.fill", tint: .orange, duration: 0.6) {
                    wm.togglePause()
                }
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

        // GPS accuracy icon — top-right corner, same as idle screen
        Image(systemName: gpsIcon(wm.currentGPSAccuracy))
            .font(.caption2)
            .foregroundStyle(gpsColor(wm.currentGPSAccuracy))
            .padding(6)
        }
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

            // Transfer status: show while the route is in flight to iPhone,
            // disappear once the iPhone confirms (provisional entry is replaced).
            transferStatusView

            Button {
                wm.reset()
                dismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var transferStatusView: some View {
        if let uuid = wm.lastFinishedUUID {
            let confirmed = sessionMgr.routes.contains {
                $0.workoutUUID == uuid && !$0.status.hasPrefix("Sending")
            }
            if confirmed {
                Label("Saved", systemImage: "iphone.and.arrow.forward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Sending to iPhone\u{2026}")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - GPS helpers

    private func gpsIcon(_ accuracy: CLLocationAccuracy) -> String {
        accuracy < 0 ? "location.slash" : accuracy < 20 ? "location.fill" : "location"
    }

    private func gpsColor(_ accuracy: CLLocationAccuracy) -> Color {
        accuracy < 0 ? .gray : accuracy < 20 ? .green : accuracy < 50 ? .yellow : .orange
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

// MARK: - HoldToActivateButton

/// A button that requires the user to hold it for `duration` seconds before activating.
/// While held, the background fills left → right as a progress indicator.
/// Releasing early resets the fill without triggering the action — prevents accidental taps.
private struct HoldToActivateButton: View {
    let icon: String
    let tint: Color
    let duration: Double
    let onActivate: () -> Void

    @GestureState private var pressing = false
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint)

            // Fill overlay that sweeps left → right
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.30))
                    .frame(width: geo.size.width * progress)
            }

            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onChange(of: pressing) { _, isPressed in
            withAnimation(isPressed
                ? .linear(duration: duration)
                : .easeOut(duration: 0.15)) {
                progress = isPressed ? 1.0 : 0.0
            }
        }
        .gesture(
            LongPressGesture(minimumDuration: duration)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in onActivate() }
        )
    }
}
