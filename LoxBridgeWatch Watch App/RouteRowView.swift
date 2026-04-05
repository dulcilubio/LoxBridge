import SwiftUI

struct RouteRowView: View {
    let route: WatchRoutePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Status line
            HStack(spacing: 4) {
                Image(systemName: statusIcon)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Text(route.status)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            // Title
            Text(title)
                .font(.body)
                .lineLimit(1)
            // Subtitle: distance + duration
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var dateString: String? {
        guard let ts = route.createdAt else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = cal.isDateInToday(date) ? "HH:mm"
            : cal.isDate(date, equalTo: .now, toGranularity: .year) ? "d MMM HH:mm"
            : "d MMM yyyy"
        return formatter.string(from: date)
    }

    private var title: String {
        route.locationName ?? route.activityTypeName ?? "Route"
    }

    private var subtitle: String {
        [
            dateString,
            route.distanceKm.map { String(format: "%.1f km", $0) },
            route.durationSeconds.map { formatDuration($0) }
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")
    }

    private var statusIcon: String {
        switch route.status {
        case "On Livelox":               return "checkmark.circle.fill"
        case "Failed":                   return "exclamationmark.triangle.fill"
        case _ where route.status.hasPrefix("Processing"): return "arrow.clockwise"
        default:                         return "doc.fill"
        }
    }

    private var statusColor: Color {
        switch route.status {
        case "On Livelox": return .green
        case "Failed":     return .red
        default:           return .secondary
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? String(format: "%d:%02d h", h, m) : String(format: "%d min", m)
    }
}
