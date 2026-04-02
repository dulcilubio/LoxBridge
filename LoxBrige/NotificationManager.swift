import Foundation
import UserNotifications
import UIKit
import OSLog

final class NotificationManager {
    static let shared = NotificationManager()

    static let uploadActionIdentifier = "UPLOAD_ACTION"
    static let ignoreActionIdentifier = "IGNORE_ACTION"
    static let laterActionIdentifier = "LATER_ACTION"
    static let categoryIdentifier = "WORKOUT_UPLOAD"
    static let workoutUUIDKey = "workoutUUID"

    private init() {}

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLogger.notification.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    func registerCategories() {
        let upload = UNNotificationAction(
            identifier: Self.uploadActionIdentifier,
            title: String(localized: "Yes"),
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionIdentifier,
            title: String(localized: "No"),
            options: []
        )
        let later = UNNotificationAction(
            identifier: Self.laterActionIdentifier,
            title: String(localized: "Later"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [upload, later, ignore],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Notification scheduling

    func scheduleUploadPrompt(workoutUUID: UUID, delayMinutes: Int? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload activity route?")
        content.subtitle = String(localized: "New activity detected")
        content.body = String(localized: "Do you want to upload the GPS route to Livelox?")
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.workoutUUIDKey: workoutUUID.uuidString]

        let trigger: UNNotificationTrigger?
        if let delayMinutes {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delayMinutes * 60), repeats: false)
        } else {
            trigger = nil
        }

        let request = UNNotificationRequest(
            identifier: workoutUUID.uuidString,
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            let logSuffix = delayMinutes == nil ? "immediately" : "in \(delayMinutes ?? 0) minutes"
            AppLogger.notification.info("Upload prompt scheduled \(logSuffix) for \(workoutUUID.uuidString)")
        } catch {
            AppLogger.notification.error("Schedule notification failed: \(error.localizedDescription)")
        }
    }

    /// Fires when a background upload begins. Gated by the "notifyOnUploadStarted" preference (default: off).
    func scheduleAutoUploadStarted() async {
        guard isEnabled("notifyOnUploadStarted", default: false) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Uploading to Livelox")
        content.body = String(localized: "We are uploading your activity route in the background.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Always shown — this is an actionable warning the user needs to see.
    func scheduleAutoUploadNeedsAuth() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Livelox not connected")
        content.body = String(localized: "Connect your Livelox account to upload activity routes automatically.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Fires when the GPX upload HTTP request succeeds. Gated by "notifyOnUploadComplete" (default: on).
    func scheduleUploadSuccess() async {
        guard isEnabled("notifyOnUploadComplete", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload complete")
        content.body = String(localized: "Your GPX route has been uploaded to Livelox.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Fires for terminal import status updates from Livelox.
    /// - Parameters:
    ///   - message: Fallback body text used when `isSuccess` is false.
    ///   - isSuccess: When true the notification congratulates the user; when false it signals a problem.
    ///   - eventName: Competition/event name from Livelox (used in the success body when available).
    func scheduleImportStatus(message: String, isSuccess: Bool, eventName: String? = nil) async {
        let key = isSuccess ? "notifyOnUploadComplete" : "notifyOnUploadFailed"
        let defaultValue = isSuccess  // complete is on by default; failed is off
        guard isEnabled(key, default: defaultValue) else { return }

        let content = UNMutableNotificationContent()
        if isSuccess {
            content.title = String(localized: "Route on Livelox")
            content.body = eventName.map {
                String(format: String(localized: "Your route from %@ is ready to replay."), $0)
            } ?? String(localized: "Your route is now on Livelox.")
        } else {
            content.title = String(localized: "Import status")
            content.body = message
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Fires when an upload fails. Gated by "notifyOnUploadFailed" (default: off).
    /// Shows a retry hint when the failure was caused by no network connectivity.
    func scheduleUploadFailure(error: Error) async {
        guard isEnabled("notifyOnUploadFailed", default: false) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Upload failed")
        content.body = (error as? AppError)?.isNetworkUnavailable == true
            ? String(localized: "No internet — will retry automatically when you reconnect.")
            : error.localizedDescription
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Action handling

    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard let workoutUUIDString = userInfo[Self.workoutUUIDKey] as? String,
              let workoutUUID = UUID(uuidString: workoutUUIDString) else {
            return
        }

        switch actionIdentifier {
        case Self.uploadActionIdentifier:
            Task {
                do {
                    AppLogger.upload.info("Upload action selected: \(workoutUUID.uuidString)")
                    try await LiveloxUploader.shared.upload(workoutUUID: workoutUUID)
                    await scheduleUploadSuccess()
                } catch {
                    AppLogger.upload.error("Upload failed: \(error.localizedDescription)")
                    await scheduleUploadFailure(error: error)
                }
            }
        case Self.laterActionIdentifier:
            Task {
                AppLogger.notification.info("Upload deferred: \(workoutUUID.uuidString)")
                await scheduleUploadPrompt(workoutUUID: workoutUUID, delayMinutes: 30)
            }
        case Self.ignoreActionIdentifier:
            AppLogger.notification.info("Upload ignored: \(workoutUUID.uuidString)")
        default:
            break
        }
    }

    // MARK: - Private helpers

    /// Returns the user's preference for a notification type.
    /// Falls back to `defaultValue` when the key has never been written (fresh install).
    private func isEnabled(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
