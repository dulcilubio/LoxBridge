import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: WatchSessionManager
    @State private var showWorkoutHelp = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Start Workout shortcut
                Section {
                    Button {
                        showWorkoutHelp = true
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
            }
            .navigationTitle("LoxBridge")
        }
        // MARK: How-to sheet
        .sheet(isPresented: $showWorkoutHelp) {
            WorkoutHelpView()
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

// MARK: - Workout instructions sheet

private struct WorkoutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "figure.run.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)

                Text("How to record a route")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Open the **Workout** app on your Watch and start an **Outdoor Run** (or any outdoor activity).\n\nLoxBridge will automatically upload the route to Livelox when you're done.")
                    .font(.caption)
                    .multilineTextAlignment(.center)

                Button("OK") { dismiss() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchSessionManager.shared)
}
