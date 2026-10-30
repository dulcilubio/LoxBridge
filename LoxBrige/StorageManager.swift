import Foundation
import OSLog

/// Lightweight metrics captured at workout-processing time and persisted alongside route metadata.
/// All fields are optional so existing stored JSON decodes without errors.
struct WorkoutStats {
    var distanceKm: Double?
    var durationSeconds: Double?
    var activityTypeName: String?
    /// Human-readable device description, e.g. "Erik's Apple Watch (Watch6,1)".
    var deviceName: String?
    /// The actual start time of the workout/activity.
    var workoutDate: Date?
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
    /// True while the route is waiting for the user to confirm before uploading to Livelox.
    /// Set when "Ask before uploading" is on; cleared when the user taps Upload or Skip.
    /// Optional so that stored JSON written before this field existed decodes without error —
    /// synthesised Codable does NOT apply default values for missing non-optional keys.
    var pendingConfirmation: Bool?
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

    private let installDateKey = "loxbridgeInstallDate"

    /// Keychain item mirroring the scan anchor and processed-workout registry.
    /// UserDefaults is wiped when the app is deleted, the Keychain (in practice) is not,
    /// so a reinstall can pick up where the previous install left off instead of either
    /// missing workouts or re-uploading old ones.
    private let scanStateKeychainKey = "scanState"

    /// After a reinstall, unprocessed workouts are only picked up automatically if they
    /// are this recent. Older ones are listed in the diagnostics view for manual import.
    private let reinstallCatchUpDays = 7

    private struct ScanState: Codable {
        var scanStartDate: Date
        var processedIDs: [String]
    }

    /// `true` once the scan anchor exists in UserDefaults, either from this install,
    /// restored from the Keychain, or freshly created. Until then the app refuses to
    /// process anything, since it cannot tell which workouts were already handled.
    private var stateReady = false
    private var lastBackup: Data?

    private init() {}

    func isProcessed(workoutUUID: UUID) -> Bool {
        queue.sync {
            ensureScanState()
            // State unknown (Keychain unreadable after a reinstall) — treat everything
            // as processed rather than risk re-uploading.
            guard stateReady else { return true }
            // Convert to Set for O(1) lookup while keeping the backing store ordered.
            return Set(processedWorkoutIDs()).contains(workoutUUID.uuidString)
        }
    }

    func markProcessed(workoutUUID: UUID) {
        queue.sync {
            ensureScanState()
            var current = processedWorkoutIDs()
            let id = workoutUUID.uuidString
            guard !current.contains(id) else { return }
            current.append(id)
            // Prune oldest entries from the front (FIFO) when over the cap.
            if current.count > maxProcessedIDs {
                current.removeFirst(current.count - maxProcessedIDs)
            }
            UserDefaults.standard.set(current, forKey: processedKey)
            backupScanState()
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
                createdAt: stats.workoutDate ?? Date(),
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
        // Exclude routes waiting for explicit user confirmation — they must not be auto-uploaded.
        queue.sync { loadAllMetadata().filter { !$0.uploaded && $0.pendingConfirmation != true } }
    }

    func markPendingConfirmation(workoutUUID: UUID) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            metadata[index].pendingConfirmation = true
            metadata[index].importStatus = "Waiting for confirmation"
            metadata[index].importStatusUpdatedAt = Date()
            saveAllMetadata(metadata)
        }
    }

    func clearPendingConfirmation(workoutUUID: UUID) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            metadata[index].pendingConfirmation = false
            saveAllMetadata(metadata)
        }
    }

    func pendingConfirmationRoutes() -> [RouteMetadata] {
        queue.sync {
            loadAllMetadata()
                .filter { $0.pendingConfirmation == true }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
    }

    /// Routes that have been uploaded but whose Livelox import status has not yet
    /// reached a terminal state. These should be re-polled when the app comes to
    /// the foreground so that the user always gets a notification even if background
    /// polling was cut short by iOS.
    func routesNeedingStatusPoll() -> [RouteMetadata] {
        queue.sync {
            loadAllMetadata().filter { route in
                guard route.uploaded else { return false }
                let s = route.importStatus ?? ""
                // Terminal states — no need to poll further.
                let terminal = s.contains("On Livelox")
                    || s.contains("Failed on Livelox")
                    || s.contains("connection expired")
                    || s.contains("Missing GPX")
                return !terminal
            }
        }
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
            // NOTE: processedWorkouts is intentionally NOT cleared here.
            // processedWorkouts means "this HealthKit workout has already been
            // handled" — it must stay set even if the GPX file is later deleted,
            // otherwise the workout would be reprocessed and re-uploaded to Livelox.
            // Only deleteRoute() and deleteAllRoutes() (explicit user actions)
            // should remove entries from processedWorkouts.
            return missing.count
        }
    }

    func deleteRoute(workoutUUID: UUID) {
        queue.sync {
            var metadata = loadAllMetadata()
            guard let index = metadata.firstIndex(where: { $0.workoutUUID == workoutUUID }) else { return }
            let entry = metadata.remove(at: index)
            saveAllMetadata(metadata)

            // processedWorkouts is intentionally NOT cleared here.
            // The UUID must stay in processedWorkouts so the workout scanner
            // never picks it up again and re-uploads it to Livelox.
            // Only deleteAllRoutes() (factory reset) clears processedWorkouts.

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
            backupScanState()
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
            // Reset the scan anchor to today so that after a factory reset only
            // future workouts are processed — not the entire HealthKit history.
            UserDefaults.standard.set(
                Calendar.current.startOfDay(for: Date()),
                forKey: installDateKey
            )
            // Overwrite the Keychain copy too, so a later reinstall doesn't restore
            // the state from before the reset.
            stateReady = true
            backupScanState()
        }
    }

    /// The earliest date from which LoxBridge should process HealthKit workouts.
    /// Set on first launch (start of that day) and never changed automatically.
    /// This prevents a new install (or app update) from scanning all historical
    /// HealthKit workouts and uploading them to Livelox. After a reinstall it is
    /// restored from the Keychain, see `ensureScanState()`.
    var workoutScanStartDate: Date {
        queue.sync {
            ensureScanState()
            // State unknown — scan nothing until it can be determined.
            return UserDefaults.standard.object(forKey: installDateKey) as? Date ?? .distantFuture
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
        // Upload state feeds into the backup (see backupScanState).
        backupScanState(metadata: metadata)
    }

    /// Makes sure the scan anchor exists in UserDefaults:
    /// - present → normal launch; also seeds the Keychain backup for installs that predate it.
    /// - missing, Keychain backup found → reinstall; restore it, catching up at most
    ///   `reinstallCatchUpDays` of workouts recorded while the app was gone.
    /// - missing, no backup → genuinely new install; start from today.
    /// - missing, Keychain unreadable → leave `stateReady` false and retry next call.
    private func ensureScanState() {
        guard !stateReady else { return }
        let defaults = UserDefaults.standard

        if defaults.object(forKey: installDateKey) is Date {
            stateReady = true
            backupScanState()
            return
        }

        switch KeychainHelper.shared.loadResult(key: scanStateKeychainKey) {
        case .found(let data):
            guard let backup = try? JSONDecoder().decode(ScanState.self, from: data) else {
                AppLogger.workout.error("Scan state backup unreadable — starting fresh")
                startFresh()
                return
            }
            let calendar = Calendar.current
            let catchUpFloor = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -reinstallCatchUpDays, to: Date()) ?? Date()
            )
            let start = max(backup.scanStartDate, catchUpFloor)
            // Keep anything this install already recorded, then add the backup.
            let current = processedWorkoutIDs()
            var merged = backup.processedIDs.filter { !current.contains($0) } + current
            if merged.count > maxProcessedIDs {
                merged.removeFirst(merged.count - maxProcessedIDs)
            }
            defaults.set(start, forKey: installDateKey)
            defaults.set(merged, forKey: processedKey)
            stateReady = true
            AppLogger.workout.info("Restored scan state from Keychain: \(merged.count) processed, scanning from \(start)")
            backupScanState()

        case .notFound:
            startFresh()

        case .failed(let status):
            AppLogger.workout.error("Scan state Keychain read failed (\(status)) — deferring")
        }
    }

    private func startFresh() {
        UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()), forKey: installDateKey)
        stateReady = true
        backupScanState()
    }

    /// Mirrors the scan anchor and processed registry to the Keychain.
    /// Workouts that were saved but never uploaded are left out, so that after a
    /// reinstall (which deletes the GPX files) they are picked up and offered again
    /// instead of being silently lost. Writes only when the content changed.
    private func backupScanState(metadata: [RouteMetadata]? = nil) {
        guard stateReady,
              let start = UserDefaults.standard.object(forKey: installDateKey) as? Date else { return }
        let notUploaded = Set((metadata ?? loadAllMetadata()).filter { !$0.uploaded }.map(\.workoutUUID.uuidString))
        let state = ScanState(
            scanStartDate: start,
            processedIDs: processedWorkoutIDs().filter { !notUploaded.contains($0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(state), data != lastBackup else { return }
        // AfterFirstUnlock: HealthKit background delivery can run while the phone is locked.
        if KeychainHelper.shared.update(data: data, key: scanStateKeychainKey, accessible: kSecAttrAccessibleAfterFirstUnlock) {
            lastBackup = data
        } else {
            AppLogger.workout.error("Scan state Keychain write failed — will retry on next change")
        }
    }
}
