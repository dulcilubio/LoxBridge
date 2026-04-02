//
//  ContentView.swift
//  LoxBrige
//
//  Created by Erik Frick on 2026-03-13.
//

import SwiftUI

extension Notification.Name {
    static let openRoutesTab = Notification.Name("OpenRoutesTab")
    static let routeListChanged = Notification.Name("RouteListChanged")
}

struct ContentView: View {
    /// The model is owned at the app level and shared with OnboardingView.
    @ObservedObject var model: AppViewModel
    @State private var selectedTab: Tab = .home
    @Environment(\.scenePhase) private var scenePhase
    /// Mirrors the `onboardingCompleted` AppStorage key so the fullScreenCover
    /// reacts when `factoryReset()` clears the key.
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(model: model)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            HistoryView(model: model)
                .tabItem { Label("Routes", systemImage: "map") }
                .tag(Tab.routes)

            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task { await model.initialize() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await model.refreshForeground() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRoutesTab)) { _ in
            selectedTab = .routes
        }
        // Show onboarding on first launch and after a factory reset.
        .fullScreenCover(isPresented: Binding(
            get: { !onboardingCompleted },
            set: { _ in }               // dismissed only by completing onboarding
        )) {
            OnboardingView(model: model)
        }
    }
}

private enum Tab: Hashable {
    case home
    case routes
    case settings
}

#Preview {
    ContentView(model: AppViewModel())
}

