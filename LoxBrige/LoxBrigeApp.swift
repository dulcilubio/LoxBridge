//
//  LoxBrigeApp.swift
//  LoxBrige
//
//  Created by Erik Frick on 2026-03-13.
//

import SwiftUI

@main
struct LoxBrigeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @StateObject private var appModel = AppViewModel()

    init() {
        // Activate WCSession as early as possible so the Watch receives
        // route updates even if the app is never brought to the foreground.
        _ = WatchSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if onboardingCompleted {
                ContentView(model: appModel)
            } else {
                OnboardingView(model: appModel)
            }
        }
    }
}
