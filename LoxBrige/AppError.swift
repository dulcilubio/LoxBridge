import Foundation

enum AppError: LocalizedError {
    case healthKitUnavailable
    case healthKitAuthorizationFailed
    case healthKitBackgroundFailed
    case workoutNotFound
    case routeNotFound
    case gpxCreationFailed
    case gpxSaveFailed
    case gpxFileMissing
    case metadataNotFound
    case oauthConfigurationMissing
    case oauthCallbackInvalid
    case oauthCancelled
    case tokenRefreshFailed
    case networkUnavailable
    case uploadFailed
    case importStatusFailed(statusCode: Int)
    case userInfoFailed

    var isNetworkUnavailable: Bool {
        if case .networkUnavailable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return String(localized: "HealthKit is not available on this device.")
        case .healthKitAuthorizationFailed:
            return String(localized: "HealthKit authorization failed.")
        case .healthKitBackgroundFailed:
            return String(localized: "Failed to enable background HealthKit delivery.")
        case .workoutNotFound:
            return String(localized: "No workout found to process.")
        case .routeNotFound:
            return String(localized: "No GPS route available for the workout.")
        case .gpxCreationFailed:
            return String(localized: "Failed to create GPX file.")
        case .gpxSaveFailed:
            return String(localized: "Failed to save GPX file.")
        case .gpxFileMissing:
            return String(localized: "GPX file could not be found.")
        case .metadataNotFound:
            return String(localized: "Workout metadata not found.")
        case .oauthConfigurationMissing:
            return String(localized: "Livelox OAuth configuration is missing.")
        case .oauthCallbackInvalid:
            return String(localized: "Authorization callback did not contain a valid code.")
        case .oauthCancelled:
            return String(localized: "Authorization was cancelled.")
        case .tokenRefreshFailed:
            return String(localized: "Your Livelox session has expired — go to Settings → Connections to reconnect.")
        case .networkUnavailable:
            return String(localized: "No internet connection — the upload will retry when you reconnect.")
        case .uploadFailed:
            return String(localized: "Failed to upload GPX file.")
        case .importStatusFailed(let code):
            return String(format: String(localized: "Import status check failed (HTTP %d)."), code)
        case .userInfoFailed:
            return String(localized: "Failed to load Livelox user info.")
        }
    }
}
