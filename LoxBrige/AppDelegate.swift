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

        // Register HKObserverQuery SYNCHRONOUSLY before returning true.
        // HealthKit fires registered observer queries as soon as the app launches for a
        // background delivery wake. If the query isn't registered by the time this method
        // returns, that wake is wasted — so we cannot defer this into an async Task.
        // isBackgroundEnabled is a plain UserDefaults bool; no async call needed.
        let hk = HealthKitManager.shared
        if hk.isBackgroundEnabled {
            hk.startWorkoutObserver()
        }

        // Async work runs concurrently — does NOT block observer registration above.
        Task {
            if hk.isBackgroundEnabled {
                try? await hk.startBackgroundDelivery()
            }
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await LiveloxUploader.shared.processPendingUploads()
        }

        return true
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
