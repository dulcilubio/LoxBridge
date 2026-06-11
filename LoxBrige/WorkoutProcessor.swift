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

    private var minDurationSeconds: Double {
        max(0, UserDefaults.standard.double(forKey: "minWorkoutDurationSecs"))
    }

    private var uploadFitnessAppRoutes: Bool {
        guard UserDefaults.standard.object(forKey: "uploadFitnessAppRoutes") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "uploadFitnessAppRoutes")
    }

    private var askBeforeUpload: Bool {
        UserDefaults.standard.bool(forKey: "askBeforeUpload")
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

    /// Processes GPS data received directly from the Watch app via WatchConnectivity.
    /// Skips HealthKit route extraction entirely — the locations are already here.
    /// Uses the same workoutUUID as the HealthKit workout, so the HealthKit observer
    /// path will see it as already processed and skip it automatically (no duplicates).
    func processDirectTransfer(_ transfer: WatchGPSTransfer) async throws {
        AppLogger.workout.info("processDirectTransfer started: uuid=\(transfer.workoutUUID), points=\(transfer.points.count), duration=\(Int(transfer.durationSeconds))s")
        guard let workoutUUID = UUID(uuidString: transfer.workoutUUID) else {
            AppLogger.workout.error("Invalid UUID in GPS transfer: \(transfer.workoutUUID)")
            return
        }
        guard !storageManager.isProcessed(workoutUUID: workoutUUID) else {
            AppLogger.workout.info("Direct transfer already processed: \(transfer.workoutUUID)")
            // Push current state so the Watch can replace any stale provisional entry.
            WatchSessionManager.shared.syncStatus()
            return
        }

        let locations: [CLLocation] = transfer.points.compactMap { pt in
            guard pt.count >= 5 else { return nil }
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: pt[0], longitude: pt[1]),
                altitude: 0,
                horizontalAccuracy: pt[4],
                verticalAccuracy: -1,
                course: -1,
                speed: pt[3],
                timestamp: Date(timeIntervalSince1970: pt[2])
            )
        }.sorted { $0.timestamp < $1.timestamp }

        guard !locations.isEmpty else {
            AppLogger.workout.error("Direct transfer has no valid locations: \(transfer.workoutUUID)")
            // Sync so the Watch drops the "Sending to iPhone…" provisional entry.
            WatchSessionManager.shared.syncStatus()
            return
        }

        let minDist = minDistanceKm
        if minDist > 0 {
            let distKm = totalDistanceKm(for: locations)
            guard distKm >= minDist else {
                AppLogger.workout.info("Direct transfer too short (\(String(format: "%.2f", distKm))km): \(transfer.workoutUUID)")
                storageManager.markProcessed(workoutUUID: workoutUUID)
                // Sync so the Watch drops the "Sending to iPhone…" provisional entry.
                WatchSessionManager.shared.syncStatus()
                return
            }
        }

        let minDur = minDurationSeconds
        if minDur > 0 {
            guard transfer.durationSeconds >= minDur else {
                AppLogger.workout.info("Direct transfer too brief (\(Int(transfer.durationSeconds))s < \(Int(minDur))s): \(transfer.workoutUUID)")
                storageManager.markProcessed(workoutUUID: workoutUUID)
                // Sync so the Watch drops the "Sending to iPhone…" provisional entry.
                WatchSessionManager.shared.syncStatus()
                return
            }
        }

        let gpxString = gpxBuilder.buildGPX(locations: locations)
        guard !gpxString.isEmpty else {
            throw AppError.gpxCreationFailed
        }

        let distKm = totalDistanceKm(for: locations)
        let stats = WorkoutStats(
            distanceKm: distKm > 0 ? distKm : nil,
            durationSeconds: transfer.durationSeconds > 0 ? transfer.durationSeconds : nil,
            activityTypeName: transfer.activityTypeName,
            deviceName: transfer.deviceName,
            workoutDate: Date(timeIntervalSince1970: transfer.startDate)
        )

        let metadata = try storageManager.saveGPX(gpxString: gpxString, workoutUUID: workoutUUID, stats: stats)
        storageManager.markProcessed(workoutUUID: workoutUUID)
        AppLogger.route.info("Direct transfer saved: \(metadata.gpxFilePath) (\(String(format: "%.2f", distKm)) km)")
        NotificationCenter.default.post(name: .routeListChanged, object: nil)

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

        if let firstLocation = locations.first {
            let sm = storageManager
            let wid = workoutUUID
            Task.detached(priority: .utility) {
                if let name = await WorkoutProcessor.reverseGeocode(location: firstLocation) {
                    await MainActor.run {
                        sm.updateLocationName(workoutUUID: wid, locationName: name)
                    }
                }
            }
        }

        if askBeforeUpload && OAuthManager.shared.hasTokens {
            storageManager.markPendingConfirmation(workoutUUID: metadata.workoutUUID)
        } else if OAuthManager.shared.hasTokens {
            await NotificationManager.shared.scheduleAutoUploadStarted()
            do {
                try await LiveloxUploader.shared.upload(workoutUUID: metadata.workoutUUID)
            } catch {
                AppLogger.upload.error("Direct transfer upload failed: \(error.localizedDescription)")
                await NotificationManager.shared.scheduleUploadFailure(error: error)
            }
        } else {
            await NotificationManager.shared.scheduleAutoUploadNeedsAuth()
        }
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

        // LoxBridge Watch app routes always pass. Apple Fitness routes pass only when
        // the toggle is on. Everything else (third-party apps) is always filtered out.
        let bundleID = workout.sourceRevision.source.bundleIdentifier
        let isLoxBridgeRoute = bundleID == "se.erikfrick.loxbridge.watchkitapp"
        let isFitnessAppRoute = bundleID.hasPrefix("com.apple.")
        guard isLoxBridgeRoute || (uploadFitnessAppRoutes && isFitnessAppRoute) else {
            AppLogger.workout.info("Workout filtered by upload type: \(workoutUUID.uuidString)")
            storageManager.markProcessed(workoutUUID: workoutUUID)
            return
        }

        let locations = try await routeExtractor.extractLocations(for: workout)
        guard !locations.isEmpty else {
            // The route wasn't found after all retries. Do NOT mark as processed —
            // the Watch→iPhone HealthKit sync can take several minutes, and the
            // foreground scan will retry this workout automatically next time the
            // app is opened.
            AppLogger.route.info("No route locations found yet for: \(workoutUUID.uuidString)")
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

        // Skip workouts shorter than the user-configured minimum duration.
        let minDur = minDurationSeconds
        if minDur > 0 {
            guard workout.duration >= minDur else {
                AppLogger.workout.info("Workout too brief (\(Int(workout.duration))s < \(Int(minDur))s): \(workoutUUID.uuidString)")
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
                    await MainActor.run {
                        sm.updateLocationName(workoutUUID: wid, locationName: name)
                        AppLogger.route.info("Location name resolved: \(name) for \(wid.uuidString)")
                    }
                }
            }
        }

        if askBeforeUpload && OAuthManager.shared.hasTokens {
            storageManager.markPendingConfirmation(workoutUUID: metadata.workoutUUID)
        } else if OAuthManager.shared.hasTokens {
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
