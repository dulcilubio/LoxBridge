import Foundation
import OSLog

actor LiveloxUploader {
    static let shared = LiveloxUploader()

    private let storageManager = StorageManager.shared
    private let oauthManager = OAuthManager.shared

    /// UUIDs for which an upload HTTP request is currently in flight.
    /// The actor boundary makes the contains/insert pair atomic — no two concurrent
    /// tasks can both pass the guard for the same UUID.
    private var uploading: Set<UUID> = []

    private init() {}

    func upload(workoutUUID: UUID) async throws {
        // Prevent a second concurrent upload of the same route (e.g. observer pipeline
        // and processPendingUploads both firing for the same workout).
        guard !uploading.contains(workoutUUID) else {
            AppLogger.upload.info("Upload already in progress for \(workoutUUID.uuidString), skipping")
            return
        }
        uploading.insert(workoutUUID)
        defer { uploading.remove(workoutUUID) }

        guard let metadata = storageManager.metadata(for: workoutUUID) else {
            throw AppError.metadataNotFound
        }

        let token = try await oauthManager.accessToken()
        guard let url = makeURL(path: "/importableRoutes") else {
            throw AppError.uploadFailed
        }

        guard FileManager.default.fileExists(atPath: metadata.gpxFilePath) else {
            storageManager.updateImportStatus(workoutUUID: workoutUUID, status: "Missing GPX file")
            throw AppError.gpxFileMissing
        }
        let gpxData = try Data(contentsOf: URL(fileURLWithPath: metadata.gpxFilePath))
        let payload: [String: Any] = [
            "id": workoutUUID.uuidString,
            "data": gpxData.base64EncodedString(),
            "deviceModel": metadata.deviceName ?? "Apple Watch"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Capture the response body so we can extract the server-assigned import ID.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError
            where urlError.code == .notConnectedToInternet
               || urlError.code == .timedOut
               || urlError.code == .networkConnectionLost {
            AppLogger.upload.error("Upload failed — no network for \(workoutUUID.uuidString): \(urlError.localizedDescription)")
            throw AppError.networkUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.upload.error("Upload HTTP \(code) for \(workoutUUID.uuidString)")
            throw AppError.uploadFailed
        }

        storageManager.markUploaded(workoutUUID: workoutUUID)
        AppLogger.upload.info("Upload succeeded for \(workoutUUID.uuidString)")

        // Use the server-assigned import ID when polling; fall back to client UUID.
        let importId = extractImportId(from: data) ?? workoutUUID.uuidString
        AppLogger.upload.info("Polling import status for id: \(importId)")
        await pollImportStatus(importId: importId, workoutUUID: workoutUUID)
    }

    /// Processes all locally saved routes that have not yet been uploaded.
    /// Skips silently when the user has not authenticated with Livelox.
    func processPendingUploads() async {
        guard oauthManager.hasTokens else {
            AppLogger.upload.info("Skipping pending uploads — not authenticated")
            return
        }
        let pending = storageManager.pendingUploads()
        guard !pending.isEmpty else { return }
        for route in pending {
            do {
                try await upload(workoutUUID: route.workoutUUID)
            } catch {
                AppLogger.upload.error("Pending upload failed for \(route.workoutUUID.uuidString): \(error.localizedDescription)")
            }
        }
    }

    /// Re-polls the Livelox import status for any route that was uploaded but whose
    /// polling was cut short (e.g. iOS suspended the app before it completed).
    /// Called on every foreground launch so the user always eventually gets a notification.
    func pollPendingStatuses() async {
        guard oauthManager.hasTokens else { return }
        let pending = storageManager.routesNeedingStatusPoll()
        guard !pending.isEmpty else { return }
        AppLogger.upload.info("Re-polling import status for \(pending.count) route(s)")
        for route in pending {
            // No initial delay — these routes were uploaded in a previous session,
            // Livelox has had plenty of time to process them.
            await pollImportStatus(
                importId: route.workoutUUID.uuidString,
                workoutUUID: route.workoutUUID,
                initialDelay: false
            )
        }
    }

    // MARK: - Private helpers

    private func makeURL(path: String) -> URL? {
        var components = URLComponents(string: AppConfiguration.shared.liveloxAPIBaseURL)
        components?.path += path
        return components?.url
    }

    /// Attempts to extract the server-assigned import ID from the upload response body.
    private func extractImportId(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary.normalizedStringValues().firstValue(forKeys: ["importId", "id", "import_id", "routeId"])
    }

    /// - Parameter initialDelay: Pass `false` when re-polling a previously uploaded
    ///   route so that stale routes are checked immediately without an artificial wait.
    private func pollImportStatus(importId: String, workoutUUID: UUID, initialDelay: Bool = true) async {
        let maxAttempts = 6
        let delaySeconds: UInt64 = 8

        if initialDelay {
            // Give the Livelox backend a moment to move the freshly-uploaded GPX into
            // Azure Blob Storage before the first poll. 5 s is enough in practice.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        }

        for attempt in 1...maxAttempts {
            do {
                let status = try await fetchImportStatus(importId: importId)
                storageManager.setLastImportStatus(status.display)
                storageManager.updateImportStatus(
                    workoutUUID: workoutUUID,
                    status: status.display,
                    liveloxURL: status.liveloxURL,
                    eventName: status.eventName,
                    className: status.className
                )
                NotificationCenter.default.post(name: .routeListChanged, object: nil)
                AppLogger.upload.info("Import status (\(attempt)/\(maxAttempts)): \(status.rawStatus)")

                if status.isTerminal {
                    let success = status.display == "On Livelox"
                    await NotificationManager.shared.scheduleImportStatus(
                        message: status.display,
                        isSuccess: success,
                        eventName: success ? status.eventName : nil
                    )
                    // Push updated status to Watch
                    WatchSessionManager.shared.syncStatus()
                    return
                }
            } catch AppError.importStatusFailed(let code) where code == 401 {
                AppLogger.upload.error("Poll 401 for \(importId) — token rejected, stopping poll loop")
                let display = "Livelox connection expired — reconnect in Settings"
                storageManager.updateImportStatus(workoutUUID: workoutUUID, status: display)
                storageManager.setLastImportStatus(display)
                await NotificationManager.shared.scheduleImportStatus(message: display, isSuccess: false)
                return
            } catch AppError.importStatusFailed(let code) where code == 404 {
                // 404 / BlobNotFound is transient — Livelox is still moving the file
                // into storage. Log and continue polling rather than giving up.
                AppLogger.upload.info("Poll 404 for \(importId) — not yet available, retrying (\(attempt)/\(maxAttempts))")
            } catch {
                AppLogger.upload.error("Import status check failed: \(error.localizedDescription)")
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }

        AppLogger.upload.warning("Polling timed out for import \(importId) — notifying user")
        let timeoutMsg = "Still processing on Livelox — check back later"
        storageManager.setLastImportStatus(timeoutMsg)
        storageManager.updateImportStatus(workoutUUID: workoutUUID, status: timeoutMsg)
        await NotificationManager.shared.scheduleImportStatus(message: timeoutMsg, isSuccess: false)
    }

    private func fetchImportStatus(importId: String) async throws -> ImportStatus {
        let token = try await oauthManager.accessToken()
        guard let url = makeURL(path: "/importableRoutes/\(importId)") else {
            throw AppError.uploadFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            AppLogger.upload.error("Poll HTTP \(statusCode) for \(importId): \(body)")
            throw AppError.importStatusFailed(statusCode: statusCode)
        }

        if let rawString = String(data: data, encoding: .utf8) {
            AppLogger.upload.info("Import status response: \(rawString)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return ImportStatus(rawStatus: "unknown", liveloxURL: nil, eventName: nil, className: nil)
        }

        let normalized = dictionary.normalizedStringValues()
        let rawStatus  = normalized.firstValue(forKeys: ["status", "state", "importStatus", "import_state"]) ?? "processing"
        let urlValue   = normalized.firstValue(forKeys: ["viewerUrl", "viewUrl", "showRouteUrl", "url"]).flatMap { URL(string: $0) }
        let eventName  = normalized.firstValue(forKeys: ["eventName", "event_name", "event"])
        let className  = normalized.firstValue(forKeys: ["className", "class_name", "class"])
        return ImportStatus(rawStatus: rawStatus, liveloxURL: urlValue?.absoluteString, eventName: eventName, className: className)
    }
}

private struct ImportStatus {
    let rawStatus: String
    let liveloxURL: String?
    let eventName: String?
    let className: String?

    /// Whether the Livelox import process has reached a final state (success or failure).
    /// Note: "error" is intentionally excluded — it can be a transient BlobNotFound
    /// during Livelox's async processing and should not stop polling prematurely.
    var isTerminal: Bool {
        let l = rawStatus.lowercased()
        return l.contains("done") || l.contains("complete") || l.contains("imported")
            || l.contains("failed")
    }

    /// User-facing status string — avoids internal API words like "pending" or "imported".
    var display: String {
        let l = rawStatus.lowercased()
        if l.contains("done") || l.contains("complete") || l.contains("imported") {
            return "On Livelox"
        } else if l.contains("failed") || l.contains("error") {
            return "Failed on Livelox — try uploading again from Routes"
        } else {
            // "pending", "processing", "queued", anything else
            return "Processing on Livelox…"
        }
    }
}
