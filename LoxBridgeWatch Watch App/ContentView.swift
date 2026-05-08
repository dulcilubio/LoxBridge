import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: WatchSessionManager
    @ObservedObject private var wm = WorkoutManager.shared

    // MARK: - Version easter egg (tap build info 5× to see full commit hash)
    @State private var versionTapCount = 0
    @State private var showVersionAlert = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Start Workout shortcut
                // Calling wm.start() changes WorkoutManager.state out of .idle,
                // which causes LoxBridgeWatchApp to swap the root view to WorkoutView
                // with zero navigation chrome — no back button, no X button.
                Section {
                    Button {
                        WorkoutManager.shared.isWorkoutOpen = true
                    } label: {
                        Label("Start Workout", systemImage: "figure.run")
                            .foregroundStyle(.green)
                    }
                }

                // MARK: Route list (inline empty state — no full-screen overlay)
                if store.routes.isEmpty {
                    Text("Routes appear here after your next activity")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(store.routes) { route in
                        NavigationLink(destination: RouteDetailView(route: route)) {
                            RouteRowView(route: route)
                        }
                    }
                }

                // MARK: Version footer — tap 5× to show full build info alert
                Section {
                    Button {
                        versionTapCount += 1
                        if versionTapCount >= 5 {
                            versionTapCount = 0
                            showVersionAlert = true
                        }
                    } label: {
                        Text(watchVersionString)
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("LoxBridge")
        }
        // MARK: In-app alert when a route reaches Livelox
        .alert("Route synced to Livelox! ◪", isPresented: Binding(
            get:  { store.newlyCompletedRoute != nil },
            set:  { if !$0 { store.newlyCompletedRoute = nil } }
        )) {
            Button("OK") { store.newlyCompletedRoute = nil }
        } message: {
            if let r = store.newlyCompletedRoute {
                let name = r.locationName ?? r.activityTypeName ?? "Your route"
                Text("\(name) has been imported to Livelox.")
            }
        }
        // MARK: Build info alert (5-tap easter egg)
        .alert("Build Info", isPresented: $showVersionAlert) {
            Button("OK") {}
        } message: {
            Text(watchVersionAlertString)
        }
        // MARK: Partial route recovery
        .confirmationDialog(
            "Incomplete recording found",
            isPresented: Binding(get: { wm.hasPartialRecovery }, set: { if !$0 { wm.discardPartialRoute() } })
        ) {
            Button("Upload partial route") { wm.recoverPartialRoute() }
            Button("Discard", role: .destructive) { wm.discardPartialRoute() }
        } message: {
            Text("A recording was interrupted. Send the partial route to Livelox?")
        }
    }

    // MARK: - Version helpers

    /// "v0.9 (2)" — tiny label shown at the bottom of the list.
    private var watchVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    /// Full build details shown in the alert after 5 taps.
    private var watchVersionAlertString: String {
        let v      = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b      = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String ?? "unknown"
        return "v\(v) build \(b)\n\(commit)"
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchSessionManager.shared)
}
