import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: WatchSessionManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                // MARK: Start Workout shortcut
                Section {
                    Button {
                        // Opens the system Workout app on the Watch.
                        // workout:// is the documented URL scheme for watchOS.
                        if let url = URL(string: "workout://") {
                            openURL(url)
                        }
                    } label: {
                        Label("Start Workout", systemImage: "figure.run")
                            .foregroundStyle(.green)
                    }
                }

                // MARK: Route list
                ForEach(store.routes) { route in
                    NavigationLink(destination: RouteDetailView(route: route)) {
                        RouteRowView(route: route)
                    }
                }
            }
            .navigationTitle("LoxBridge")
            .overlay {
                if store.routes.isEmpty {
                    ContentUnavailableView(
                        "No routes yet",
                        systemImage: "map",
                        description: Text("Routes appear here after your next activity")
                    )
                }
            }
        }
        // MARK: In-app alert when a route reaches Livelox
        .alert("Route on Livelox! 🎉", isPresented: Binding(
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
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchSessionManager.shared)
}
