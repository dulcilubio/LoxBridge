import Foundation
import HealthKit
import CoreLocation
import OSLog

final class RouteExtractor {
    private let healthStore = HKHealthStore()

    func extractLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        // Apple Watch saves the workout first; the GPS route syncs separately and
        // may take 1–5 minutes to appear on iPhone. We retry with increasing delays.
        // Two strategies are tried on each attempt:
        //   1. predicateForObjects(from: workout) — the correct association predicate
        //   2. time-range predicate                — fallback for routes that exist
        //      in HealthKit but whose workout association hasn't propagated yet
        var routes: [HKWorkoutRoute] = try await fetchRoutes(for: workout)
        if routes.isEmpty {
            for delaySecs: UInt64 in [15, 30, 60, 120] {
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

    /// Fetches routes associated with the workout via two strategies:
    /// 1. `predicateForObjects(from: workout)` — direct association (preferred)
    /// 2. Time-range overlap fallback — catches routes that are in HealthKit but
    ///    whose link to the workout hasn't propagated yet after Watch→iPhone sync.
    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        // Strategy 1: association predicate
        let associated = try await fetchRoutesByPredicate(
            HKQuery.predicateForObjects(from: workout)
        )
        if !associated.isEmpty { return associated }

        // Strategy 2: time-range fallback — any route that overlaps the workout window
        let timePredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate.addingTimeInterval(60), // small buffer for GPS lag
            options: .strictStartDate
        )
        return try await fetchRoutesByPredicate(timePredicate)
    }

    private func fetchRoutesByPredicate(_ predicate: NSPredicate) async throws -> [HKWorkoutRoute] {
        let routeType = HKSeriesType.workoutRoute()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: routeType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            self.healthStore.execute(query)
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
