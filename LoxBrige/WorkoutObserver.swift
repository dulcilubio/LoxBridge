import Foundation
import HealthKit
import OSLog

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
            Task {
                await self?.fetchLatestWorkoutAndProcess()
                completionHandler()
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
