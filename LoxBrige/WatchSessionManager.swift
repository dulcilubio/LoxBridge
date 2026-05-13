import Foundation
import WatchConnectivity
import UIKit
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
            let existing = cached.first(where: { $0.workoutUUID == route.workoutUUID.uuidString })
            return WatchRoutePayload(
                workoutUUID: route.workoutUUID.uuidString,
                status: watchStatusString(for: route),
                distanceKm: route.distanceKm,
                durationSeconds: route.durationSeconds,
                activityTypeName: route.activityTypeName,
                locationName: route.locationName,
                createdAt: route.createdAt?.timeIntervalSince1970,
                points: existing?.points ?? [],
                speeds: existing?.speeds
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

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            AppLogger.upload.error("WatchSessionManager: activation failed: \(error.localizedDescription)")
        } else {
            AppLogger.upload.info("WatchSessionManager: activated, state=\(activationState.rawValue), paired=\(session.isPaired), watchInstalled=\(session.isWatchAppInstalled), reachable=\(session.isReachable)")
        }
        if activationState == .activated {
            // Push current cached routes to Watch now that the session is ready
            pushToWatch(loadCachedPayloads())
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        AppLogger.upload.info("WatchSessionManager: reachability changed → \(session.isReachable), pendingFileTransfers=\(session.hasContentPending)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLogger.upload.info("WatchSessionManager: session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        AppLogger.upload.info("WatchSessionManager: session deactivated — reactivating")
        WCSession.default.activate()
    }

    /// Receives GPS data sent from the Watch app via sendMessageData() when the
    /// session is reachable. This is the primary delivery path — faster and more
    /// reliable than transferFile, and the only one that works in the simulator.
    func session(_ session: WCSession,
                 didReceiveMessageData messageData: Data,
                 replyHandler: @escaping (Data) -> Void) {
        AppLogger.upload.info("WatchSessionManager: didReceiveMessageData, \(messageData.count) bytes")
        replyHandler(Data()) // acknowledge immediately so Watch errorHandler doesn't fire

        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatchGPSMessage") {
            AppLogger.workout.warning("WatchGPSMessage background task expired")
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }

        Task {
            defer { UIApplication.shared.endBackgroundTask(bgTaskID) }
            do {
                let transfer = try JSONDecoder().decode(WatchGPSTransfer.self, from: messageData)
                try await WorkoutProcessor.shared.processDirectTransfer(transfer)
            } catch {
                AppLogger.workout.error("GPS message processing failed: \(error.localizedDescription)")
            }
        }
    }

    /// Receives GPS transfer files sent from the Watch app via transferFile().
    /// Fallback path used when the iPhone was not reachable at workout end.
    /// Called on an arbitrary background thread by WatchConnectivity — even when
    /// the iPhone app is suspended, the system wakes it to deliver the file.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        AppLogger.upload.info("WatchSessionManager: didReceive file, metadata=\(String(describing: file.metadata))")
        guard file.metadata?["type"] as? String == "WatchGPSTransfer" else {
            AppLogger.upload.info("WatchSessionManager: ignoring file with unexpected type")
            return
        }
        AppLogger.workout.info("Received direct GPS transfer from Watch")

        // Read the file synchronously while the delegate still holds it.
        // WatchConnectivity may move or delete the file the moment this method
        // returns, so reading it in an async Task (as was done before) is a race.
        guard let data = try? Data(contentsOf: file.fileURL) else {
            AppLogger.workout.error("Direct GPS transfer: failed to read file synchronously")
            return
        }

        // `var` so the expiration handler can reference it by name and end the task.
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatchGPSTransfer") {
            // Expiration handler: iOS is about to suspend us. End the task so
            // the system doesn't penalise the app for leaving it open.
            // processDirectTransfer saves the GPX before uploading, so even if
            // the upload is cut short, the route is already persisted and will
            // be retried when the app next opens via processPendingUploads().
            AppLogger.workout.warning("WatchGPSTransfer background task expired")
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }

        Task {
            defer { UIApplication.shared.endBackgroundTask(bgTaskID) }
            do {
                let transfer = try JSONDecoder().decode(WatchGPSTransfer.self, from: data)
                try await WorkoutProcessor.shared.processDirectTransfer(transfer)
            } catch {
                AppLogger.workout.error("Direct GPS transfer failed: \(error.localizedDescription)")
            }
        }
    }
}
