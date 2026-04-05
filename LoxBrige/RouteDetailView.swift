import SwiftUI

/// Full-screen detail for a single route — GPS track, stats, metadata and Livelox link.
/// Opened by tapping a row in HistoryView; "View on Livelox" lives here (not in the row).
struct RouteDetailView: View {
    let route: RouteMetadata

    private var points: [[Double]] {
        WatchSessionManager.shared.cachedPayload(for: route.workoutUUID)?.points ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Track map
                Group {
                    if points.count >= 2 {
                        RouteTrackView(points: points)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "map")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("Track not available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.0, contentMode: .fit)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // MARK: Stats
                if route.distanceKm != nil || route.durationSeconds != nil {
                    HStack(spacing: 0) {
                        if let dist = route.distanceKm {
                            StatCard(value: String(format: "%.2f", dist),
                                     unit: "km", icon: "figure.run")
                        }
                        if let dur = route.durationSeconds {
                            if route.distanceKm != nil { Divider().frame(height: 44) }
                            StatCard(value: formatDuration(dur),
                                     unit: "duration", icon: "clock")
                        }
                        if let dist = route.distanceKm,
                           let dur  = route.durationSeconds,
                           dist > 0, dur > 0 {
                            Divider().frame(height: 44)
                            StatCard(value: formatPace(distanceKm: dist, durationSeconds: dur),
                                     unit: "/km", icon: "gauge.with.dots.needle.33percent")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // MARK: Metadata
                VStack(alignment: .leading, spacing: 8) {
                    if let event = route.eventName {
                        Label(event, systemImage: "flag.fill")
                            .font(.subheadline)
                    }
                    if let cls = route.className {
                        Label(cls, systemImage: "list.bullet")
                            .font(.subheadline)
                    }
                    if let location = route.locationName {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let device = route.deviceName {
                        Label(device, systemImage: "applewatch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Status
                if let status = route.importStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: View on Livelox — prominent button, clearly separate from the row tap
                if let liveloxURL = route.liveloxURL,
                   let url = URL(string: liveloxURL) {
                    Link(destination: url) {
                        Label("View on Livelox", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding()
        }
        .navigationTitle(route.locationName ?? route.activityTypeName ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatPace(distanceKm: Double, durationSeconds: Double) -> String {
        let secPerKm = durationSeconds / distanceKm
        let m = Int(secPerKm) / 60
        let s = Int(secPerKm) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let value: String
    let unit:  String
    let icon:  String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.purple)
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
