import SwiftUI

@main
struct LoxBridgeWatchApp: App {
    @StateObject private var store = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
