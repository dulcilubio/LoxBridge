import Foundation
import HealthKit
import OSLog

/// Why a HealthKit workout does or doesn't appear in LoxBridge.
/// Mirrors the checks in `WorkoutProcessor.process(workout:)`, in the same order.
enum WorkoutDiagnosticStatus {
    case uploaded
    case saved
    case notOutdoor
    case skipped
    case beforeInstall
    case sourceDisabled
    case noRoute
    case waiting

    var label: String {
        switch self {
        case .uploaded:       return String(localized: "Uploaded to Livelox")
        case .saved:          return String(localized: "Saved, not uploaded")
        case .notOutdoor:     return String(localized: "Not an outdoor activity")
        case .skipped:        return String(localized: "Skipped by filter or removed")
        case .beforeInstall:  return String(localized: "Recorded before LoxBridge was installed")
        case .sourceDisabled: return String(localized: "Recording app not enabled")
        case .noRoute:        return String(localized: "No GPS route in Health")
        case .waiting:        return String(localized: "Not processed yet")
        }
    }

    /// `true` when the workout is missing from LoxBridge for a reason the user can override.
    var isMissing: Bool {
        switch self {
        case .skipped, .beforeInstall, .sourceDisabled, .waiting: return true
        default: return false
        }
    }
}

struct DiagnosedWorkout: Identifiable {
    let workout: HKWorkout
    let hasRoute: Bool
    let status: WorkoutDiagnosticStatus

    var id: UUID { workout.uuid }
    var activityName: String { workout.workoutActivityType.displayName }
    var sourceName: String { workout.sourceRevision.source.name }
    var canImport: Bool { hasRoute && status.isMissing }
}

struct WorkoutDiagnosticsReport {
    let healthDataAvailable: Bool
    let accessRequested: Bool
    let workouts: [DiagnosedWorkout]

    var workoutCount: Int { workouts.count }
    var routeCount: Int { workouts.filter(\.hasRoute).count }
}

/// Lists recent HealthKit workouts — ignoring the install-date anchor — and explains
/// for each one why it is or isn't in LoxBridge. Read-only except that newly seen
/// recording apps are registered, just as the normal pipeline would.
final class WorkoutDiagnostics {
    private let healthStore = HKHealthStore()
    private let routeExtractor = RouteExtractor()
    private let storageManager = StorageManager.shared

    func run(days: Int = 30) async -> WorkoutDiagnosticsReport {
        guard HKHealthStore.isHealthDataAvailable() else {
            return WorkoutDiagnosticsReport(healthDataAvailable: false, accessRequested: false, workouts: [])
        }
        let accessRequested = await HealthKitManager.shared.readAuthorizationStatusText() == "Authorized"

        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let workouts: [HKWorkout]
        do {
            workouts = try await fetchWorkouts(since: since)
        } catch {
            AppLogger.healthKit.error("Diagnostics workout fetch failed: \(error.localizedDescription)")
            workouts = []
        }

        var diagnosed: [DiagnosedWorkout] = []
        for workout in workouts {
            let hasRoute = await routeExtractor.hasRoute(for: workout)
            diagnosed.append(DiagnosedWorkout(
                workout: workout,
                hasRoute: hasRoute,
                status: status(for: workout, hasRoute: hasRoute)
            ))
        }
        AppLogger.healthKit.info("Diagnostics: \(diagnosed.count) workouts, \(diagnosed.filter(\.hasRoute).count) with route")
        return WorkoutDiagnosticsReport(healthDataAvailable: true, accessRequested: accessRequested, workouts: diagnosed)
    }

    private func status(for workout: HKWorkout, hasRoute: Bool) -> WorkoutDiagnosticStatus {
        if let metadata = storageManager.metadata(for: workout.uuid) {
            return metadata.uploaded ? .uploaded : .saved
        }
        guard workout.workoutActivityType.isOutdoorActivity else { return .notOutdoor }
        // Without a route there is nothing to import, whatever else applies — e.g.
        // Garmin Connect writes workouts to Health but not their GPS routes.
        guard hasRoute else { return .noRoute }
        if storageManager.isProcessed(workoutUUID: workout.uuid) { return .skipped }
        if workout.startDate < storageManager.workoutScanStartDate { return .beforeInstall }

        let bundleID = workout.sourceRevision.source.bundleIdentifier
        if bundleID != "se.erikfrick.loxbridge.watchkitapp" {
            let registry = WorkoutSourceRegistry.shared
            registry.register(bundleID: bundleID, displayName: workout.sourceRevision.source.name)
            if !registry.isEnabled(bundleID: bundleID) { return .sourceDisabled }
        }
        return .waiting
    }

    private func fetchWorkouts(since: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
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
