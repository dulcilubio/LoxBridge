import Foundation
import WatchConnectivity
import OSLog

/// Manages the WatchConnectivity session on the iPhone side.
/// Caches the last 5 route payloads (with GPS points) and pushes them
/// to the paired Watch app whenever the session is active.
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    private let payloadsKey = "watchRoutePayloads"

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Public API

    /// Called from WorkoutProcessor immediately after extracting GPS points
    /// while the CLLocation array is still in memory.
    func sendWithPoints(payload: WatchRoutePayload) {
        var cached = loadCachedPayloads()
        cached.removeAll { $0.workoutUUID == payload.workoutUUID }
        cached.insert(payload, at: 0)
        let trimmed = Array(cached.prefix(5))
        saveCachedPayloads(trimmed)
        pushToWatch(trimmed)
    }

    /// Called after a Livelox import status changes. Rebuilds payloads from
    /// StorageManager, preserving existing GPS points from cache.
    func syncStatus() {
        let routes = StorageManager.shared.recentRoutes(limit: 5)
        let cached = loadCachedPayloads()

        // Rebuild strictly from the current route list — no stale entries survive.
        // Preserve GPS points for routes that are still present.
        let updated: [WatchRoutePayload] = routes.map { route in
            let existingPoints = cached.first(where: { $0.workoutUUID == route.workoutUUID.uuidString })?.points ?? []
            return WatchRoutePayload(
                workoutUUID: route.workoutUUID.uuidString,
                status: watchStatusString(for: route),
                distanceKm: route.distanceKm,
                durationSeconds: route.durationSeconds,
                activityTypeName: route.activityTypeName,
                locationName: route.locationName,
                createdAt: route.createdAt?.timeIntervalSince1970,
                points: existingPoints
            )
        }

        saveCachedPayloads(updated)
        pushToWatch(updated)
    }

    /// Returns the cached payload for a given workout UUID, or nil if not in cache.
    func cachedPayload(for workoutUUID: UUID) -> WatchRoutePayload? {
        loadCachedPayloads().first { $0.workoutUUID == workoutUUID.uuidString }
    }

    // MARK: - Private helpers

    private func pushToWatch(_ payloads: [WatchRoutePayload]) {
        guard WCSession.default.activationState == .activated else { return }
        guard let jsonData = try? JSONEncoder().encode(payloads),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [Any] else {
            AppLogger.upload.error("WatchSessionManager: failed to encode payloads")
            return
        }
        do {
            try WCSession.default.updateApplicationContext(["routes": jsonObject])
            AppLogger.upload.info("WatchSessionManager: pushed \(payloads.count) route(s) to Watch")
        } catch {
            AppLogger.upload.error("WatchSessionManager: updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    private func watchStatusString(for route: RouteMetadata) -> String {
        let s = route.importStatus ?? ""
        if s.contains("On Livelox")   { return "On Livelox" }
        if s.contains("Processing")   { return "Processing\u{2026}" }
        if s.contains("Failed") || s.contains("failed") { return "Failed" }
        if route.uploaded              { return "Uploaded" }
        return "Saved"
    }

    private func loadCachedPayloads() -> [WatchRoutePayload] {
        guard let data = UserDefaults.standard.data(forKey: payloadsKey),
              let decoded = try? JSONDecoder().decode([WatchRoutePayload].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveCachedPayloads(_ payloads: [WatchRoutePayload]) {
        guard let data = try? JSONEncoder().encode(payloads) else { return }
        UserDefaults.standard.set(data, forKey: payloadsKey)
    }

    // MARK: - WCSessionDelegate (iPhone requires these three methods)

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            // Push current cached routes to Watch now that the session is ready
            pushToWatch(loadCachedPayloads())
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for Watch switching (iPhone can pair with multiple Watches)
        WCSession.default.activate()
    }
}
