import Foundation
import HealthKit
import CoreLocation
import OSLog

private extension HKWorkoutActivityType {
    /// Returns `true` for activity types that are likely to have a GPS route.
    var isOutdoorActivity: Bool {
        switch self {
        case .running, .walking, .hiking, .cycling, .swimming,
             .crossCountrySkiing, .downhillSkiing, .snowboarding,
             .skatingSports, .rowing, .paddleSports, .sailing,
             .surfingSports, .climbing, .other:
            return true
        default:
            return false
        }
    }

    /// Human-readable display name, with types common in orienteering listed first.
    var displayName: String {
        switch self {
        case .running:            return "Running"
        case .hiking:             return "Hiking"
        case .walking:            return "Walking"
        case .cycling:            return "Cycling"
        case .crossCountrySkiing: return "Cross-country skiing"
        case .downhillSkiing:     return "Downhill skiing"
        case .snowboarding:       return "Snowboarding"
        case .climbing:           return "Climbing"
        case .swimming:           return "Swimming"
        case .rowing:             return "Rowing"
        case .paddleSports:       return "Paddling"
        case .sailing:            return "Sailing"
        case .surfingSports:      return "Surfing"
        case .skatingSports:      return "Skating"
        case .other:              return "Workout"
        default:                  return "Workout"
        }
    }
}

final class WorkoutProcessor {
    static let shared = WorkoutProcessor()

    private let storageManager = StorageManager.shared
    private let routeExtractor = RouteExtractor()
    private let gpxBuilder = GPXBuilder()

    private var minDistanceKm: Double {
        max(0, UserDefaults.standard.double(forKey: "minWorkoutDistanceKm"))
    }

    private init() {}

    /// Builds a human-readable device description from the HealthKit workout metadata.
    ///
    /// HealthKit stores two useful fields on every workout:
    ///   - `device.name`                  → the user's custom device name, e.g. "Erik's Apple Watch"
    ///   - `sourceRevision.productType`   → the hardware model identifier, e.g. "Watch6,1" or "iPhone14,5"
    ///
    /// Combining both gives a string like "Erik's Apple Watch (Watch6,1)" that Livelox
    /// can display as the recording device. Falls back gracefully when either field is absent.
    private func deviceName(for workout: HKWorkout) -> String {
        let customName   = workout.device?.name
        let productType  = workout.sourceRevision.productType

        switch (customName, productType) {
        case (let name?, let type?): return "\(name) (\(type))"
        case (let name?, nil):       return name
        case (nil, let type?):       return type
        case (nil, nil):             return workout.sourceRevision.source.name
        }
    }

    /// Reverse-geocodes a location into a human-readable area name (e.g. "Skatås, Göteborg").
    /// Returns nil if the lookup fails or the device is offline.
    /// Static so it can be called from a `Task.detached` without capturing `self`.
    private static func reverseGeocode(location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                guard let p = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let parts = [p.locality, p.administrativeArea].compactMap { $0 }
                let name = parts.isEmpty ? p.country : parts.joined(separator: ", ")
                continuation.resume(returning: name)
            }
        }
    }

    private struct SubsampledRoute {
        let points: [[Double]]
        let speeds: [Double]?
    }

    /// Subsamples a CLLocation array to at most `maxPoints` evenly-spaced entries.
    /// Returns both [[lat, lon]] pairs and per-point speeds normalized to 0…1
    /// (0 = slowest, 1 = fastest on this route). Speeds are nil if unavailable.
    private func subsample(locations: [CLLocation], maxPoints: Int) -> SubsampledRoute {
        let sampled: [CLLocation]
        if locations.count <= maxPoints {
            sampled = locations
        } else {
            let step = Double(locations.count - 1) / Double(maxPoints - 1)
            sampled = (0..<maxPoints).map { i in
                let idx = min(Int((Double(i) * step).rounded()), locations.count - 1)
                return locations[idx]
            }
        }

        let points = sampled.map { [$0.coordinate.latitude, $0.coordinate.longitude] }

        // Build raw speeds (m/s): prefer CLLocation.speed; fall back to distance/time delta.
        var raw: [Double] = sampled.enumerated().map { i, loc in
            if loc.speed >= 0 { return loc.speed }
            if i > 0 {
                let dt = loc.timestamp.timeIntervalSince(sampled[i - 1].timestamp)
                let dist = loc.distance(from: sampled[i - 1])
                if dt > 0.3 { return dist / dt }
            }
            return -1.0
        }
        // Fill gaps by propagating neighbours.
        for i in 1..<raw.count     { if raw[i] < 0 { raw[i] = raw[i - 1] } }
        for i in stride(from: raw.count - 2, through: 0, by: -1) { if raw[i] < 0 { raw[i] = raw[i + 1] } }

        let valid = raw.filter { $0 >= 0 }
        guard valid.count > 1,
              let lo = valid.min(), let hi = valid.max(), hi - lo > 0.1
        else {
            // No meaningful variance — return constant mid-point (shows uniform yellow)
            let uniform = Array(repeating: 0.5, count: sampled.count)
            return SubsampledRoute(points: points, speeds: uniform)
        }

        let normalized = raw.map { max(0.0, min(1.0, ($0 - lo) / (hi - lo))) }
        return SubsampledRoute(points: points, speeds: normalized)
    }

    /// Returns the total route distance in kilometres by summing consecutive point distances.
    private func totalDistanceKm(for locations: [CLLocation]) -> Double {
        guard locations.count > 1 else { return 0 }
        var total: Double = 0
        for index in 1..<locations.count {
            total += locations[index - 1].distance(from: locations[index])
        }
        return total / 1000
    }

    func process(workout: HKWorkout) async throws {
        let workoutUUID = workout.uuid
        guard !storageManager.isProcessed(workoutUUID: workoutUUID) else {
            AppLogger.workout.info("Workout already processed: \(workoutUUID.uuidString)")
            return
        }

        // Skip workout types that don't produce GPS routes (indoor, gym, etc.).
        guard workout.workoutActivityType.isOutdoorActivity else {
            AppLogger.workout.info("Skipping non-outdoor workout type \(workout.workoutActivityType.rawValue): \(workoutUUID.uuidString)")
            storageManager.markProcessed(workoutUUID: workoutUUID)
            return
        }

        let locations = try await routeExtractor.extractLocations(for: workout)
        guard !locations.isEmpty else {
            AppLogger.route.info("No route locations for workout: \(workoutUUID.uuidString)")
            throw AppError.routeNotFound
        }

        // Skip workouts shorter than the user-configured minimum distance.
        let minDist = minDistanceKm
        if minDist > 0 {
            let distKm = totalDistanceKm(for: locations)
            guard distKm >= minDist else {
                AppLogger.workout.info("Workout too short (\(String(format: "%.2f", distKm))km < \(minDist)km): \(workoutUUID.uuidString)")
                storageManager.markProcessed(workoutUUID: workoutUUID)
                return
            }
        }

        let gpxString = gpxBuilder.buildGPX(locations: locations)
        guard !gpxString.isEmpty else {
            AppLogger.route.error("GPX creation failed: \(workoutUUID.uuidString)")
            throw AppError.gpxCreationFailed
        }

        let distKm = totalDistanceKm(for: locations)
        let stats = WorkoutStats(
            distanceKm: distKm > 0 ? distKm : nil,
            durationSeconds: workout.duration > 0 ? workout.duration : nil,
            activityTypeName: workout.workoutActivityType.displayName,
            deviceName: deviceName(for: workout),
            workoutDate: workout.startDate
        )

        let metadata = try storageManager.saveGPX(gpxString: gpxString, workoutUUID: workoutUUID, stats: stats)
        storageManager.markProcessed(workoutUUID: workoutUUID)
        AppLogger.route.info("GPX saved: \(metadata.gpxFilePath) (\(String(format: "%.2f", distKm)) km, \(Int(workout.duration))s)")
        NotificationCenter.default.post(name: .routeListChanged, object: nil)

        // Send route to Watch app — must happen while locations array is still in scope.
        let sub = subsample(locations: locations, maxPoints: 200)
        let watchPayload = WatchRoutePayload(
            workoutUUID: workoutUUID.uuidString,
            status: "Saved",
            distanceKm: stats.distanceKm,
            durationSeconds: stats.durationSeconds,
            activityTypeName: stats.activityTypeName,
            locationName: nil,
            createdAt: stats.workoutDate?.timeIntervalSince1970,
            points: sub.points,
            speeds: sub.speeds
        )
        WatchSessionManager.shared.sendWithPoints(payload: watchPayload)

        // Reverse-geocode the starting point to get a human-readable area name.
        // Done in a detached Task so it doesn't block the upload pipeline.
        // storageManager and workoutUUID are captured directly — no need to capture self.
        if let firstLocation = locations.first {
            let sm = storageManager
            let wid = workoutUUID
            Task.detached(priority: .utility) {
                if let name = await WorkoutProcessor.reverseGeocode(location: firstLocation) {
                    sm.updateLocationName(workoutUUID: wid, locationName: name)
                    AppLogger.route.info("Location name resolved: \(name) for \(wid.uuidString)")
                }
            }
        }

        if OAuthManager.shared.hasTokens {
            await NotificationManager.shared.scheduleAutoUploadStarted()
            do {
                try await LiveloxUploader.shared.upload(workoutUUID: metadata.workoutUUID)
            } catch {
                AppLogger.upload.error("Auto upload failed: \(error.localizedDescription)")
                await NotificationManager.shared.scheduleUploadFailure(error: error)
            }
        } else {
            await NotificationManager.shared.scheduleAutoUploadNeedsAuth()
        }
    }
}
