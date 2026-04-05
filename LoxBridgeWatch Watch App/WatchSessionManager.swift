import Foundation
import WatchConnectivity

/// Manages the WatchConnectivity session on the Watch side.
/// Receives route payloads from the paired iPhone and publishes them
/// for the SwiftUI views to display.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    @Published var routes: [WatchRoutePayload] = []

    private let payloadsKey = "watchRoutePayloads"

    private override init() {
        super.init()
        // Load cached routes immediately so the UI has data on cold launch
        // before the iPhone has a chance to push an update.
        routes = loadCachedPayloads()

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let routesArray = applicationContext["routes"] as? [Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: routesArray),
              let decoded = try? JSONDecoder().decode([WatchRoutePayload].self, from: jsonData)
        else { return }

        Task { @MainActor in
            self.routes = decoded
            self.saveCachedPayloads(decoded)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    // MARK: - Local persistence

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
}
