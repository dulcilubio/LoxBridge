import Foundation

/// Lightweight metrics captured at workout-processing time and persisted alongside route metadata.
/// All fields are optional so existing stored JSON decodes without errors.
struct WorkoutStats {
    var distanceKm: Double?
    var durationSeconds: Double?
    var activityTypeName: String?
    /// Human-readable device description, e.g. "Erik's Apple Watch (Watch6,1)".
    var deviceName: String?
}

struct RouteMetadata: Codable {
    let workoutUUID: UUID
    let gpxFilePath: String
    var uploaded: Bool
    let createdAt: Date?
    var importStatus: String?
    var importStatusUpdatedAt: Date?
    var liveloxURL: String?
    // Stats — populated at processing time, nil for routes recorded before this version.
    var distanceKm: Double?
    var durationSeconds: Double?
    var activityTypeName: String?
    var locationName: String?
    /// Device that recorded the workout, e.g. "Erik's Apple Watch (Watch6,1)".
    var deviceName: String?
    /// Livelox event name returned from the import status poll, if available.
    var eventName: String?
    /// Livelox class name returned from the import status poll, if available.
    var className: String?
}

final class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let processedKey = "processedWorkouts"
    private let metadataKey = "routeMetadata"
    private let lastImportStatusKey = "lastImportStatus"

    /// Serial queue that serialises all reads and writes, preventing race conditions.
    private let queue = DispatchQueue(label: "com.loxbrige.storagemanager", qos: .utility)

    /// Maximum number of processed workout UUIDs kept in UserDefaults.
    private let maxProcessedIDs = 200

    private init() {}

    func isProcessed(workoutUUID: UUID) -> Bool {
        // Convert to Set for O(1) lookup while keeping the backing store ordered.
        queue.sync { Set(processedWorkoutIDs()).contains(workoutUUID.uuidString) }
    }

    func markProcessed(workoutUUID: UUID) {
        queue.sync {
            var current = processedWorkoutIDs()
            let id = workoutUUID.uuidString
            guard !current.contains(id) else { return }
            current.append(id)
            // Prune oldest entries from the front (FIFO) when over the cap.
            if current.count > maxProcessedIDs {
                current.removeFirst(current.count - maxProcessedIDs)
            }
            UserDefaults.standard.set(current, forKey: processedKey)
        }
    }

    func saveGPX(gpxString: String, workoutUUID: UUID, stats: WorkoutStats = WorkoutStats()) throws -> RouteMetadata {
        let directory = try routesDirectory()
        let fileName = "route_\(workoutUUID.uuidString).gpx"
        let fileURL = directory.appendingPathComponent(fileName)

        do {
            try gpxString.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw AppError.gpxSaveFailed
        }

        return queue.sync {
            var metadata = loadAllMetadata()
            let entry = RouteMetadata(
                workoutUUID: workoutUUID,
                gpxFilePath: fileURL.path,
                uploaded: false,
                createdAt: Date(),
                importStatus: "Pending upload",
                importStatusUpdatedAt: Date(),
                liveloxURL: nil,
                distanceKm: stats.distanceKm,
                durationSeconds: stats.durationSeconds,
                activityTypeName: stats.activityTypeName,
                locationName: nil,
                deviceName: stats.deviceName
            )
            metadata.removeAll { $0.workoutUUID == workoutUUID }
            metadata.append(entry)
            saveAllMetadata(metadata)
            return entry
        }
    }

    /// Updates the reverse-geocoded location name for a route after it is looked up asynchronously.
    func updateLocationName(workoutUUID: UUID, locationName: String) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            metadata[index].locationName = locationName
            saveAllMetadata(metadata)
        }
    }

    func metadata(for workoutUUID: UUID) -> RouteMetadata? {
        queue.sync { loadAllMetadata().first { $0.workoutUUID == workoutUUID } }
    }

    func markUploaded(workoutUUID: UUID) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            metadata[index].uploaded = true
            metadata[index].importStatus = "Uploaded"
            metadata[index].importStatusUpdatedAt = Date()
            saveAllMetadata(metadata)
        }
    }

    func pendingUploads() -> [RouteMetadata] {
        queue.sync { loadAllMetadata().filter { !$0.uploaded } }
    }

    func updateImportStatus(
        workoutUUID: UUID,
        status: String,
        liveloxURL: String? = nil,
        eventName: String? = nil,
        className: String? = nil
    ) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            metadata[index].importStatus = status
            metadata[index].importStatusUpdatedAt = Date()
            if let liveloxURL  { metadata[index].liveloxURL  = liveloxURL  }
            if let eventName   { metadata[index].eventName   = eventName   }
            if let className   { metadata[index].className   = className   }
            saveAllMetadata(metadata)
        }
    }

    func recentRoutes(limit: Int = 10) -> [RouteMetadata] {
        queue.sync {
            loadAllMetadata()
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                .prefix(limit)
                .map { $0 }
        }
    }

    func pruneMissingRoutes() -> Int {
        queue.sync {
            var metadata = loadAllMetadata()
            let missing = metadata.filter { !fileManager.fileExists(atPath: $0.gpxFilePath) }
            guard !missing.isEmpty else { return 0 }
            metadata.removeAll { entry in
                missing.contains { $0.workoutUUID == entry.workoutUUID }
            }
            saveAllMetadata(metadata)

            var processed = processedWorkoutIDs()
            let missingIDs = Set(missing.map { $0.workoutUUID.uuidString })
            processed.removeAll { missingIDs.contains($0) }
            UserDefaults.standard.set(processed, forKey: processedKey)
            return missing.count
        }
    }

    func deleteRoute(workoutUUID: UUID) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            let entry = metadata.remove(at: index)
            saveAllMetadata(metadata)

            var processed = processedWorkoutIDs()
            processed.removeAll { $0 == workoutUUID.uuidString }
            UserDefaults.standard.set(processed, forKey: processedKey)

            if fileManager.fileExists(atPath: entry.gpxFilePath) {
                try? fileManager.removeItem(atPath: entry.gpxFilePath)
            }
        }
    }

    /// Deletes every GPX file and route metadata, but keeps the processed-workout
    /// registry so previously detected workouts are not re-queued after the clear.
    /// Use this when the user clears the Routes list from within the app.
    func deleteAllRouteFiles() {
        queue.sync {
            let metadata = loadAllMetadata()
            for route in metadata {
                try? fileManager.removeItem(atPath: route.gpxFilePath)
            }
            UserDefaults.standard.removeObject(forKey: metadataKey)
        }
    }

    /// Deletes every GPX file and clears all route-related persistent state.
    /// Called as part of a factory reset — does not affect HealthKit permissions.
    func deleteAllRoutes() {
        queue.sync {
            let metadata = loadAllMetadata()
            for route in metadata {
                try? fileManager.removeItem(atPath: route.gpxFilePath)
            }
            UserDefaults.standard.removeObject(forKey: metadataKey)
            UserDefaults.standard.removeObject(forKey: processedKey)
            UserDefaults.standard.removeObject(forKey: lastImportStatusKey)
        }
    }

    func setLastImportStatus(_ status: String) {
        queue.sync { UserDefaults.standard.set(status, forKey: lastImportStatusKey) }
    }

    func lastImportStatus() -> String {
        queue.sync { UserDefaults.standard.string(forKey: lastImportStatusKey) ?? "No import status yet" }
    }

    // MARK: - Private helpers (must always be called on `queue`)

    /// Returns the ordered list of processed workout UUID strings (oldest first).
    private func processedWorkoutIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: processedKey) ?? []
    }

    private func routesDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let routes = base.appendingPathComponent("Routes", isDirectory: true)
        if !fileManager.fileExists(atPath: routes.path) {
            try fileManager.createDirectory(at: routes, withIntermediateDirectories: true)
        }
        return routes
    }

    private func loadAllMetadata() -> [RouteMetadata] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey) else {
            return []
        }
        return (try? JSONDecoder().decode([RouteMetadata].self, from: data)) ?? []
    }

    private func saveAllMetadata(_ metadata: [RouteMetadata]) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
