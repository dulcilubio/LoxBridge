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

    /// Guards against the same scan running more than once at a time.
    /// Three callers (AppDelegate, scenePhase observer, HKObserverQuery) can all
    /// fire within milliseconds of each other at app launch — this flag lets the
    /// first one through and silently skips the rest until it finishes.
    private var isScanning = false

    /// Fetches the 20 most recent workouts from HealthKit (last 90 days), skips any
    /// that have already been processed, and runs the full pipeline on each remaining one.
    private func processAllUnprocessedWorkouts() async {
        guard !isScanning else {
            AppLogger.workout.info("Scan already in progress, skipping")
            return
        }
        isScanning = true
        defer { isScanning = false }

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

    /// Fetches up to `limit` workouts from the last 90 days, sorted newest-first.
    /// The 90-day window avoids scanning all-time HealthKit history, which can
    /// include hundreds of old Apple Fitness workouts that will never have a
    /// LoxBridge-recorded GPS route attached to them.
    private func fetchRecentWorkouts(limit: Int) async throws -> [HKWorkout] {
        let since = Date().addingTimeInterval(-90 * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
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
