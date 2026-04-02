import Foundation
import HealthKit
import CoreLocation
import OSLog

final class RouteExtractor {
    private let healthStore = HKHealthStore()

    func extractLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        // Apple Watch saves the workout metadata first; GPS route data is synced separately
        // and may arrive seconds to minutes later. Retry with increasing delays.
        var routes: [HKWorkoutRoute] = try await fetchRoutes(for: workout)
        if routes.isEmpty {
            for delaySecs: UInt64 in [10, 20, 30] {
                AppLogger.route.info("No routes yet, retrying in \(delaySecs)s…")
                try await Task.sleep(nanoseconds: delaySecs * 1_000_000_000)
                routes = try await fetchRoutes(for: workout)
                if !routes.isEmpty { break }
            }
        }
        if routes.isEmpty {
            AppLogger.route.info("No HKWorkoutRoute samples found after retries")
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
