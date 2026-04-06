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
                await self?.processAllUnprocessedWorkouts()
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

    /// Called on app foreground to catch workouts that were missed while
    /// the app was suspended (e.g. Watch workouts recorded between observer fires).
    func scanForMissedWorkouts() {
        Task {
            await processAllUnprocessedWorkouts()
        }
    }

    // MARK: - Private

    /// Fetches the 20 most recent workouts from HealthKit, skips any that have
    /// already been processed, and runs the full pipeline on each remaining one.
    ///
    /// Using the 20 most recent instead of limit:1 ensures that workouts recorded
    /// while the phone was offline (or whose GPS route had not yet synced) are
    /// all retried the next time the observer fires or the app comes to the foreground.
    private func processAllUnprocessedWorkouts() async {
        do {
            let workouts = try await fetchRecentWorkouts(limit: 20)
            let unprocessed = workouts.filter {
                !StorageManager.shared.isProcessed(workoutUUID: $0.uuid)
            }
            guard !unprocessed.isEmpty else {
                AppLogger.workout.info("No unprocessed workouts found")
                return
            }
            AppLogger.workout.info("Processing \(unprocessed.count) unprocessed workout(s)")
            for workout in unprocessed {
                do {
                    try await WorkoutProcessor.shared.process(workout: workout)
                } catch {
                    AppLogger.workout.error("Workout \(workout.uuid.uuidString) failed: \(error.localizedDescription)")
                }
            }
        } catch {
            AppLogger.workout.error("Failed to fetch workouts: \(error.localizedDescription)")
        }
    }

    private func fetchRecentWorkouts(limit: Int) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: workoutType, predicate: nil, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            self.healthStore.execute(query)
        }
    }
}
