import SwiftUI

struct RouteDetailView: View {
    let route: WatchRoutePayload

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {

                // Track visualization or placeholder
                Group {
                    if route.points.count >= 2 {
                        RouteTrackView(points: route.points)
                    } else {
                        Image(systemName: "map")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.0, contentMode: .fit)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Distance + duration
                HStack(spacing: 16) {
                    if let km = route.distanceKm {
                        StatCell(value: String(format: "%.2f", km), label: "km")
                    }
                    if let secs = route.durationSeconds {
                        StatCell(value: formatDuration(secs), label: "time")
                    }
                }
                .font(.caption)

                // Status
                Text(route.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(route.locationName ?? route.activityTypeName ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "%d min", m)
    }
}

private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value).bold()
            Text(label).foregroundStyle(.secondary)
        }
    }
}
