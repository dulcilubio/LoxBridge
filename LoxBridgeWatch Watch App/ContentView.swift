import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: WatchSessionManager

    var body: some View {
        NavigationStack {
            List(store.routes) { route in
                NavigationLink(destination: RouteDetailView(route: route)) {
                    RouteRowView(route: route)
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
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchSessionManager.shared)
}
