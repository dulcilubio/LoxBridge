import Foundation
import Combine
import CoreLocation
import OSLog
import UIKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var healthKitStatus: String = "Not authorized"
    @Published var liveloxStatus: String = "Not connected"
    @Published var lastError: String?
    @Published var backgroundEnabled: Bool = false
    @Published var liveloxAccountName: String = "Not connected"
    @Published var importStatus: String = "No import status yet"
    @Published var recentRoutes: [RouteMetadata] = []

    private let healthKitManager = HealthKitManager.shared
    private let oauthManager = OAuthManager.shared
    private var isInitialized = false
    private var routeListObserver: AnyCancellable?

    func initialize() async {
        routeListObserver = NotificationCenter.default
            .publisher(for: .routeListChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.recentRoutes = StorageManager.shared.recentRoutes(limit: 50)
                self.importStatus = StorageManager.shared.lastImportStatus()
            }
        await refreshStatus()
        isInitialized = true
        backgroundEnabled = healthKitManager.isBackgroundEnabled
        // Observer is started by AppDelegate on every launch (foreground + background).
        // Nothing to do here — startWorkoutObserver() is a no-op if already running.
    }

    func requestHealthKitAuthorization() async {
        do {
            try await healthKitManager.requestAuthorization()
            try await enableBackgroundProcessing()
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connectLivelox() async {
        do {
            try await oauthManager.authorize()
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnectLivelox() async {
        oauthManager.logout()
        await refreshStatus()
    }

    func enableBackgroundProcessing() async throws {
        healthKitManager.isBackgroundEnabled = true
        backgroundEnabled = true
        try await healthKitManager.startBackgroundDelivery()
        healthKitManager.startWorkoutObserver()
    }

    func disableBackgroundProcessing() async {
        do {
            try await healthKitManager.stopBackgroundDelivery()
            healthKitManager.stopWorkoutObserver()
            healthKitManager.isBackgroundEnabled = false
            backgroundEnabled = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Clears all local app data and Livelox credentials, then resets onboarding
    /// so the privacy notice is presented again on next launch.
    /// HealthKit permissions cannot be removed programmatically — the user must
    /// do that in Settings → Health → Apps → LoxBridge.
    func factoryReset() async {
        await disableBackgroundProcessing()
        StorageManager.shared.deleteAllRoutes()
        oauthManager.logout()
        UserDefaults.standard.removeObject(forKey: "minWorkoutDistanceKm")
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        lastError = nil
        await refreshStatus()
    }

    /// Called when the app returns to the foreground. Refreshes status, detects
    /// HealthKit permission revocation, and retries any pending uploads.
    func refreshForeground() async {
        guard isInitialized else { return }
        let previous = healthKitStatus
        await refreshStatus()
        if previous == "Authorized" && healthKitStatus != "Authorized" && backgroundEnabled {
            await disableBackgroundProcessing()
            lastError = String(localized: "HealthKit access was removed. Re-authorize in Settings to resume automatic uploads.")
        }
        // Retry uploads that previously failed due to no network connection.
        await LiveloxUploader.shared.processPendingUploads()
        // Re-poll status for routes that were uploaded but whose background polling
        // was cut short by iOS. This ensures the user always gets a notification.
        await LiveloxUploader.shared.pollPendingStatuses()
    }

    func refreshStatus() async {
        healthKitStatus = await healthKitManager.readAuthorizationStatusText()
        liveloxStatus = oauthManager.isAuthorized ? "Connected" : "Not connected"
        importStatus = StorageManager.shared.lastImportStatus()
        _ = StorageManager.shared.pruneMissingRoutes()
        recentRoutes = StorageManager.shared.recentRoutes(limit: 50)

        if oauthManager.isAuthorized {
            if let cached = oauthManager.cachedUserInfo() {
                liveloxAccountName = cached.displayName
            }
            do {
                let info = try await oauthManager.fetchUserInfo()
                liveloxAccountName = info.displayName
            } catch {
                if liveloxAccountName.isEmpty {
                    liveloxAccountName = "Unknown"
                }
            }
        } else {
            liveloxAccountName = "Not connected"
        }
    }

    /// Deletes all local GPX files and route metadata, but keeps the processed-workout
    /// registry so previously detected workouts are not re-queued.
    func deleteAllRoutes() async {
        StorageManager.shared.deleteAllRouteFiles()
        WatchSessionManager.shared.syncStatus()
        await refreshStatus()
    }

    func deleteRoutes(at offsets: IndexSet) async {
        let routes = recentRoutes
        for index in offsets {
            guard index < routes.count else { continue }
            StorageManager.shared.deleteRoute(workoutUUID: routes[index].workoutUUID)
        }
        WatchSessionManager.shared.syncStatus()
        await refreshStatus()
    }

#if targetEnvironment(simulator)
    /// Injects a synthetic ~3 km GPS loop into the full pipeline so the upload
    /// and polling flows can be exercised in the simulator without a real workout.
    func simulateWorkout() async {
        lastError = nil

        // ~3 km elliptical loop around central Gothenburg.
        let centerLat = 57.7089
        let centerLon = 11.9746
        let workoutStart = Date().addingTimeInterval(-1800) // pretend it started 30 min ago
        let pointCount = 60
        let durationSeconds: Double = 1800

        let locations: [CLLocation] = (0...pointCount).map { i in
            let fraction = Double(i) / Double(pointCount)
            let angle = fraction * 2 * .pi
            let lat = centerLat + 0.014 * sin(angle)        // ~1.5 km N–S radius
            let lon = centerLon + 0.020 * cos(angle)        // ~1.1 km E–W radius
            let altitude = 15.0 + 8.0 * sin(angle * 2)
            let timestamp = workoutStart.addingTimeInterval(fraction * durationSeconds)
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                timestamp: timestamp
            )
        }

        let workoutUUID = UUID()
        let gpxString = GPXBuilder().buildGPX(locations: locations)
        guard !gpxString.isEmpty else {
            lastError = "Simulated GPX build failed."
            return
        }

        // Compute distance from the synthetic route points.
        var simDistKm: Double = 0
        if locations.count > 1 {
            for i in 1..<locations.count {
                simDistKm += locations[i - 1].distance(from: locations[i])
            }
            simDistKm /= 1000
        }
        let simStats = WorkoutStats(
            distanceKm: simDistKm > 0 ? simDistKm : nil,
            durationSeconds: durationSeconds,
            activityTypeName: "Simulated Run",
            deviceName: "\(UIDevice.current.name) (Simulator)"
        )

        do {
            let metadata = try StorageManager.shared.saveGPX(gpxString: gpxString, workoutUUID: workoutUUID, stats: simStats)
            StorageManager.shared.markProcessed(workoutUUID: workoutUUID)
            AppLogger.workout.info("Simulated workout injected: \(metadata.gpxFilePath)")

            // Send GPS points to Watch — simulateWorkout() bypasses WorkoutProcessor
            // so we must call sendWithPoints() here explicitly.
            let watchPoints = locations.map { [$0.coordinate.latitude, $0.coordinate.longitude] }
            let watchPayload = WatchRoutePayload(
                workoutUUID: workoutUUID.uuidString,
                status: "Saved",
                distanceKm: simStats.distanceKm,
                durationSeconds: simStats.durationSeconds,
                activityTypeName: simStats.activityTypeName,
                locationName: nil,
                createdAt: workoutStart.timeIntervalSince1970,
                points: watchPoints
            )
            WatchSessionManager.shared.sendWithPoints(payload: watchPayload)

            if OAuthManager.shared.hasTokens {
                await NotificationManager.shared.scheduleAutoUploadStarted()
                do {
                    try await LiveloxUploader.shared.upload(workoutUUID: workoutUUID)
                } catch {
                    lastError = error.localizedDescription
                    await NotificationManager.shared.scheduleUploadFailure(error: error)
                }
            } else {
                await NotificationManager.shared.scheduleAutoUploadNeedsAuth()
            }
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }
#endif
}
