import Foundation
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationManager.shared.registerCategories()
        Task {
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await LiveloxUploader.shared.processPendingUploads()

            // Start the HealthKit observer on every launch — both foreground and
            // background. Without this, HealthKit background-delivery wakes the app
            // but the observer query (registered only via SwiftUI .task{}) is never
            // started, so workouts are silently missed until the user opens the app.
            await Self.startObserverIfEnabled()
        }
        return true
    }

    private static func startObserverIfEnabled() async {
        let hk = HealthKitManager.shared
        guard hk.isBackgroundEnabled,
              await hk.readAuthorizationStatusText() == "Authorized" else { return }
        try? await hk.startBackgroundDelivery()
        hk.startWorkoutObserver() // no-op if already running
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NotificationCenter.default.post(name: .openRoutesTab, object: nil)
        }
        NotificationManager.shared.handle(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
