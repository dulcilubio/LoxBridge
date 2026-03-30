import Foundation
import HealthKit
import OSLog

final class HealthKitManager {
    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()
    private var workoutObserver: WorkoutObserver?
    private let backgroundEnabledKey = "backgroundDeliveryEnabled"

    /// `true` only in the simulator. Used to bypass APIs that are
    /// genuinely unsupported in the simulator (background delivery),
    /// while still allowing real HealthKit auth calls to go through.
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private init() {}

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    }

    private func logAuthorizationStatus(context: String) {
        let workoutType = HKObjectType.workoutType()
        let routeType = HKSeriesType.workoutRoute()
        let workoutStatus = healthStore.authorizationStatus(for: workoutType)
        let routeStatus = healthStore.authorizationStatus(for: routeType)
        AppLogger.healthKit.info("HealthKit share status [\(context)] available=\(HKHealthStore.isHealthDataAvailable()), workout=\(String(describing: workoutStatus)), route=\(String(describing: routeStatus))")
    }

    func readAuthorizationStatusText() async -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            AppLogger.healthKit.error("HealthKit not available on this device")
            return "Unavailable"
        }
        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { status, error in
                if let error {
                    AppLogger.healthKit.error("Authorization request status error: \(error.localizedDescription)")
                    continuation.resume(returning: "Unknown")
                    return
                }
                switch status {
                case .unnecessary:
                    continuation.resume(returning: "Authorized")
                case .shouldRequest:
                    continuation.resume(returning: "Not authorized")
                case .unknown:
                    continuation.resume(returning: "Unknown")
                @unknown default:
                    continuation.resume(returning: "Unknown")
                }
            }
        }
    }

    var isBackgroundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: backgroundEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: backgroundEnabledKey) }
    }

    func requestAuthorization() async throws {
        logAuthorizationStatus(context: "before-request")
        guard HKHealthStore.isHealthDataAvailable() else {
            AppLogger.healthKit.error("HealthKit not available on this device")
            throw AppError.healthKitUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { success, error in
                if let error {
                    AppLogger.healthKit.error("Authorization error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    AppLogger.healthKit.error("Authorization request failed")
                    continuation.resume(throwing: AppError.healthKitAuthorizationFailed)
                    return
                }
                self.logAuthorizationStatus(context: "after-request")
                self.healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: self.readTypes) { status, error in
                    if let error {
                        AppLogger.healthKit.error("Authorization request status error: \(error.localizedDescription)")
                        continuation.resume(throwing: AppError.healthKitAuthorizationFailed)
                        return
                    }
                    switch status {
                    case .unnecessary:
                        AppLogger.healthKit.info("Authorization read status: Authorized")
                        continuation.resume()
                    case .shouldRequest:
                        AppLogger.healthKit.error("Authorization read status: Not authorized")
                        continuation.resume(throwing: AppError.healthKitAuthorizationFailed)
                    case .unknown:
                        AppLogger.healthKit.error("Authorization read status: Unknown")
                        continuation.resume(throwing: AppError.healthKitAuthorizationFailed)
                    @unknown default:
                        AppLogger.healthKit.error("Authorization read status: Unknown")
                        continuation.resume(throwing: AppError.healthKitAuthorizationFailed)
                    }
                }
            }
        }
    }

    func startBackgroundDelivery() async throws {
        if isSimulator {
            AppLogger.healthKit.info("Background delivery enabled (simulator override)")
            return
        }
        let workoutType = HKObjectType.workoutType()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
                if let error {
                    AppLogger.healthKit.error("Background delivery error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    AppLogger.healthKit.error("Background delivery failed")
                    continuation.resume(throwing: AppError.healthKitBackgroundFailed)
                    return
                }
                AppLogger.healthKit.info("Background delivery enabled")
                continuation.resume()
            }
        }
    }

    func stopBackgroundDelivery() async throws {
        if isSimulator {
            AppLogger.healthKit.info("Background delivery disabled (simulator override)")
            return
        }
        let workoutType = HKObjectType.workoutType()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.disableBackgroundDelivery(for: workoutType) { success, error in
                if let error {
                    AppLogger.healthKit.error("Disable background error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    AppLogger.healthKit.error("Disable background failed")
                    continuation.resume(throwing: AppError.healthKitBackgroundFailed)
                    return
                }
                AppLogger.healthKit.info("Background delivery disabled")
                continuation.resume()
            }
        }
    }

    func startWorkoutObserver() {
        if workoutObserver != nil {
            return
        }
        let observer = WorkoutObserver(healthStore: healthStore)
        observer.start()
        workoutObserver = observer
        AppLogger.healthKit.info("Workout observer started")
    }

    func stopWorkoutObserver() {
        guard let workoutObserver else {
            return
        }
        workoutObserver.stop()
        self.workoutObserver = nil
        AppLogger.healthKit.info("Workout observer stopped")
    }
}
