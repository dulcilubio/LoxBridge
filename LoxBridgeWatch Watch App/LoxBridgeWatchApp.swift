import SwiftUI

@main
struct LoxBridgeWatchApp: App {
    @StateObject private var store = WatchSessionManager.shared
    @StateObject private var wm    = WorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            // Root-level state switch — no navigation stack, no system chrome.
            // WorkoutView has no back button, no X button, no swipe-to-dismiss:
            // the only way in/out is through WorkoutManager.state changes.
            if wm.state == .idle && !wm.isWorkoutOpen {
                ContentView()
                    .environmentObject(store)
            } else {
                WorkoutView()
            }
        }
    }
}
