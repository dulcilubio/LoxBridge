import Foundation
import HealthKit
import CoreLocation
import OSLog

final class RouteExtractor {
    private let healthStore = HKHealthStore()

    func extractLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes = try await fetchRoutes(for: workout)
        if routes.isEmpty {
            AppLogger.route.info("No HKWorkoutRoute samples found")
            return []
        }

        var allLocations: [CLLocation] = []
        for route in routes {
            let routeLocations = try await fetchLocations(for: route)
            allLocations.append(contentsOf: routeLocations)
        }
        AppLogger.route.info("Route points collected: \(allLocations.count)")
        return allLocations.sorted { $0.timestamp < $1.timestamp }
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: routeType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let routes = samples as? [HKWorkoutRoute] ?? []
                continuation.resume(returning: routes)
            }
            healthStore.execute(query)
        }
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let locations {
                    collected.append(contentsOf: locations)
                }
                if done {
                    continuation.resume(returning: collected)
                }
            }
            healthStore.execute(query)
        }
    }
}
