import SwiftUI

/// Displays the history of GPS routes that have been detected and their upload status.
struct HistoryView: View {
    @ObservedObject var model: AppViewModel

    @State private var showDeleteAllConfirmation = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if model.recentRoutes.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "map")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No routes yet")
                            .font(.headline)
                        Text("Complete an outdoor activity with your Apple Watch and it will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.recentRoutes, id: \.workoutUUID) { route in
                            RouteRow(
                                route: route,
                                dateFormatter: Self.dateFormatter,
                                onUpload: route.uploaded ? nil : {
                                    Task {
                                        do {
                                            try await LiveloxUploader.shared.upload(workoutUUID: route.workoutUUID)
                                            await model.refreshStatus()
                                        } catch {
                                            model.lastError = error.localizedDescription
                                        }
                                    }
                                }
                            )
                            // Leading swipe → share GPX file
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let gpxURL = route.gpxFileURL {
                                    ShareLink(
                                        item: gpxURL,
                                        preview: SharePreview(
                                            route.shareLabel,
                                            icon: Image(systemName: "map.fill")
                                        )
                                    ) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                        .onDelete { offsets in
                            Task { await model.deleteRoutes(at: offsets) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Route History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading: Delete All (only when routes exist)
                ToolbarItem(placement: .topBarLeading) {
                    if !model.recentRoutes.isEmpty {
                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                // Trailing: standard swipe-to-delete toggle
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .confirmationDialog(
                model.recentRoutes.count == 1
                    ? "Delete 1 route?"
                    : "Delete all \(model.recentRoutes.count) routes?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All Routes", role: .destructive) {
                    Task { await model.deleteAllRoutes() }
                }
            } message: {
                Text("GPX files are permanently deleted from this device. Routes already on Livelox are not affected.")
            }
            .refreshable { await model.refreshStatus() }
        }
    }
}

// MARK: - Route row

private struct RouteRow: View {
    let route: RouteMetadata
    let dateFormatter: DateFormatter
    let onUpload: (() -> Void)?

    // MARK: Derived state

    private var hasFailed: Bool {
        guard let s = route.importStatus else { return false }
        let l = s.lowercased()
        return l.contains("failed") || l.contains("expired")
    }

    private var isOnLivelox: Bool {
        route.importStatus == "On Livelox"
    }

    private var statusIcon: (name: String, color: Color) {
        if hasFailed          { return ("exclamationmark.circle.fill", .red) }
        if isOnLivelox        { return ("checkmark.circle.fill", .green) }
        if route.uploaded     { return ("arrow.up.circle.fill", .blue) }
        return ("clock.circle", .orange)
    }

    private var statusText: String {
        route.importStatus ?? (route.uploaded
            ? String(localized: "Sent to Livelox")
            : String(localized: "Pending upload"))
    }

    private var statusColor: Color {
        if hasFailed      { return .red }
        if isOnLivelox    { return .secondary }
        if route.uploaded { return .blue }
        return .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon.name)
                .foregroundStyle(statusIcon.color)
                .imageScale(.large)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                // Date + activity type
                HStack(spacing: 6) {
                    if let date = route.createdAt {
                        Text(dateFormatter.string(from: date))
                            .font(.subheadline)
                    } else {
                        Text("Unknown date")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let type = route.activityTypeName {
                        Text("· \(type)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Livelox event & class — shown when the import poll returns them
                if route.eventName != nil || route.className != nil {
                    HStack(spacing: 6) {
                        if let event = route.eventName {
                            Label(event, systemImage: "flag.fill")
                        }
                        if let cls = route.className {
                            Label(cls, systemImage: "list.bullet")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                }

                // Stats row: distance · duration · pace
                let hasStats = route.distanceKm != nil || route.durationSeconds != nil
                if hasStats {
                    HStack(spacing: 10) {
                        if let dist = route.distanceKm {
                            Label(String(format: "%.1f km", dist), systemImage: "figure.run")
                        }
                        if let dur = route.durationSeconds {
                            Label(formatDuration(dur), systemImage: "clock")
                        }
                        if let dist = route.distanceKm,
                           let dur = route.durationSeconds,
                           dist > 0, dur > 0 {
                            Label(formatPace(distanceKm: dist, durationSeconds: dur), systemImage: "gauge.with.dots.needle.33percent")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }

                // Location
                if let location = route.locationName {
                    Label(location, systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Status — hidden once successfully on Livelox (the green icon says it all)
                if !isOnLivelox {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                if let liveloxURL = route.liveloxURL,
                   let url = URL(string: liveloxURL) {
                    Link("View on Livelox →", destination: url)
                        .font(.caption2)
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Upload / retry button
                    if let onUpload, !route.uploaded {
                        Button("Upload to Livelox") { onUpload() }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                    } else if hasFailed {
                        Button("Try Again") { onUpload?() }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }

                    // Share GPX — visible whenever the local file exists
                    if let gpxURL = route.gpxFileURL {
                        ShareLink(
                            item: gpxURL,
                            preview: SharePreview(
                                route.shareLabel,
                                icon: Image(systemName: "map.fill")
                            )
                        ) {
                            Label("Share GPX", systemImage: "square.and.arrow.up")
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

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
        return String(format: "%d:%02d /km", m, s)
    }
}

// MARK: - RouteMetadata helpers

private extension RouteMetadata {
    /// File URL for the GPX file — nil if the file no longer exists on disk.
    var gpxFileURL: URL? {
        let url = URL(fileURLWithPath: gpxFilePath)
        return FileManager.default.fileExists(atPath: gpxFilePath) ? url : nil
    }

    /// Human-readable label used as the share sheet preview title.
    var shareLabel: String {
        var parts: [String] = []
        if let type = activityTypeName { parts.append(type) }
        if let dist = distanceKm { parts.append(String(format: "%.1f km", dist)) }
        if let name = locationName { parts.append(name) }
        return parts.isEmpty ? String(localized: "GPX Route") : parts.joined(separator: " · ")
    }
}

#Preview {
    HistoryView(model: AppViewModel())
}
