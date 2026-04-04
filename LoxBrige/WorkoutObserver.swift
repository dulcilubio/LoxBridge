import Foundation
import HealthKit
import OSLog
import UIKit

final class WorkoutObserver {
    private let healthStore: HKHealthStore
    private let workoutType = HKObjectType.workoutType()
    private var query: HKObserverQuery?

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func start() {
        let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                AppLogger.workout.error("Observer error: \(error.localizedDescription)")
                completionHandler()
                return
            }
            AppLogger.workout.info("Observer triggered")

            // Acknowledge the wake immediately so HealthKit does not time us out.
            // If completionHandler is not called within ~30 s HealthKit penalises the
            // app and may stop delivering future background wakes.
            completionHandler()

            // Request extended background execution time so the full pipeline
            // (route extraction retries + Livelox upload + polling) can finish before
            // iOS suspends the process.
            let bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "WorkoutProcessing") {
                AppLogger.workout.warning("Background task expired before processing finished")
            }

            Task {
                await self?.fetchLatestWorkoutAndProcess()
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }
        healthStore.execute(query)
        self.query = query
    }

    func stop() {
        if let query {
            healthStore.stop(query)
            self.query = nil
        }
    }

    private func fetchLatestWorkoutAndProcess() async {
        do {
            let workout = try await fetchLatestWorkout()
            try await WorkoutProcessor.shared.process(workout: workout)
        } catch {
            AppLogger.workout.error("Workout processing failed: \(error.localizedDescription)")
        }
    }

    private func fetchLatestWorkout() async throws -> HKWorkout {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: workoutType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(throwing: AppError.workoutNotFound)
                    return
                }
                continuation.resume(returning: workout)
            }
            healthStore.execute(query)
        }
    }
}
