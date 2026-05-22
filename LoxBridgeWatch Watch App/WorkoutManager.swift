import Combine
import HealthKit
import CoreLocation
import WatchConnectivity
import WatchKit
import OSLog

private let logger = Logger(subsystem: "se.erikfrick.loxbridge", category: "workout")

/// Manages a single outdoor-running HKWorkoutSession on the Watch.
///
/// When the session ends the finished workout is saved to HealthKit automatically.
/// The paired iPhone's HKObserverQuery will detect it and run the full pipeline
/// (GPX build → Livelox upload) without any extra Watch→iPhone communication.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {

    static let shared = WorkoutManager()

    enum State { case idle, active, paused, finished }

    @Published var state:          State  = .idle
    @Published var elapsedSeconds: Int    = 0
    @Published var distanceMeters: Double = 0
    @Published var errorMessage:   String? = nil
    /// UUID of the most recently finished workout; used by WorkoutView to track
    /// whether the iPhone has confirmed receipt of the GPS transfer.
    @Published var lastFinishedUUID: String? = nil
    /// GPS horizontal accuracy (metres) while idle, updated by `idleLocationMgr`.
    /// -1 means no fix yet. Used to show the GPS status icon on the idle screen.
    @Published var currentGPSAccuracy: CLLocationAccuracy = -1
    /// True while the workout screen is open (including the idle/start sub-screen).
    /// Set to true by ContentView's "Start Workout" button so WorkoutView is shown
    /// before start() is called; cleared by reset() when the user taps Done.
    @Published var isWorkoutOpen = false
    @Published var hasPartialRecovery = false
    @Published var isStarting = false
    @Published var locationAuthStatus: CLAuthorizationStatus = CLLocationManager().authorizationStatus

    private let healthStore  = HKHealthStore()
    private var session:     HKWorkoutSession?
    private var builder:     HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var locationMgr: CLLocationManager?
    /// Lightweight location manager used only on the idle screen to track GPS
    /// accuracy before a workout starts. Stopped as soon as start() is called.
    private var idleLocationMgr: CLLocationManager?
    private var displayTimer: Timer?

    /// Set to `true` immediately before CLLocationManager starts (in beginSession),
    /// and `false` in stop() before stopUpdatingLocation(). This avoids the race
    /// where location updates arrive before HKWorkoutSession fires its .running
    /// delegate callback — previously those early points were silently dropped
    /// because the guard checked `state == .active` which wasn't set yet.
    private var isRouteRecording = false

    /// All accurate GPS locations collected during this workout.
    /// Sent to iPhone via WCSession.transferFile() at stop() so the route
    /// appears in LoxBridge immediately, without waiting for HealthKit sync.
    private var allRecordedLocations: [CLLocation] = []
    private var partialSessionUUID: UUID = UUID()
    private var persistTimer: Timer?
    private var partialRecoveryURLs: [URL] = []

    private override init() {
        super.init()
        checkForPartialRecovery()
        startIdleLocationUpdates()
        // Pre-request HealthKit authorization silently at launch.
        // On watchOS the user must approve on iPhone, so this runs while
        // the phone is most likely nearby (just after install / first open).
        // Subsequent launches where auth is already granted return immediately,
        // meaning start() works fully offline without needing the iPhone at all.
        Task { try? await requestAuthorization() }
    }

    /// Starts a low-priority CLLocationManager purely to track GPS accuracy on
    /// the idle screen. Stops automatically when the workout starts.
    private func startIdleLocationUpdates() {
        let mgr = CLLocationManager()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        idleLocationMgr = mgr
    }

    private func stopIdleLocationUpdates() {
        idleLocationMgr?.stopUpdatingLocation()
        idleLocationMgr = nil
    }

    // MARK: - Public API

    /// Non-async: stores the Task internally so cancelStart() can cancel it.
    func start() {
        guard !isStarting else { return }
        let status = idleLocationMgr?.authorizationStatus ?? CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            if status == .notDetermined {
                idleLocationMgr?.requestWhenInUseAuthorization()
                errorMessage = "Allow location access when prompted, then try again."
            } else {
                errorMessage = "Location access is required. Enable it in Settings → Privacy & Security → Location Services → LoxBridge on your iPhone."
            }
            return
        }
        isStarting = true
        stopIdleLocationUpdates()
        startTask = Task {
            defer {
                isStarting = false
                startTask = nil
            }
            do {
                // Race the actual start against a 15-second timeout so we never
                // get permanently stuck if HealthKit authorization hangs.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // Only request authorization if not yet granted.
                        // Re-requesting when iPhone is not nearby causes a hang;
                        // once granted it is remembered and the call returns instantly.
                        let alreadyAuthorized = self.healthStore
                            .authorizationStatus(for: .workoutType()) == .sharingAuthorized
                        if !alreadyAuthorized {
                            try await self.requestAuthorization()
                        }
                        try Task.checkCancellation()   // don't open session if cancelled
                        try await self.beginSession()
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw StartTimeoutError()
                    }
                    try await group.next()!
                    group.cancelAll()
                }
            } catch is CancellationError {
                // Cancelled via cancelStart() — silent reset, return to idle.
                startIdleLocationUpdates()
            } catch is StartTimeoutError {
                // HealthKit didn't respond in time — silently reset so the user
                // can tap Start again, which will re-request authorization.
                logger.warning("start() timed out — resetting to idle for retry")
                startIdleLocationUpdates()
            } catch {
                errorMessage = error.localizedDescription
                startIdleLocationUpdates()
            }
        }
    }

    /// Cancels an in-progress start() and returns to the idle screen.
    func cancelStart() {
        startTask?.cancel()
        startTask = nil
        isStarting = false
        startIdleLocationUpdates()
    }

    private var startTask: Task<Void, Never>?

    private struct StartTimeoutError: LocalizedError {
        var errorDescription: String? {
            "Keep your iPhone nearby and try again — HealthKit authorization requires the companion app."
        }
    }

    func togglePause() {
        guard let session else { return }
        state == .active ? session.pause() : session.resume()
    }

    func stop() async {
        // Set .finished FIRST so that any concurrent call (e.g. onDisappear firing while
        // this async chain is already in flight) hits the guard immediately and returns,
        // preventing session.end() being called twice ("already Ended" error).
        guard state == .active || state == .paused,
              let session, let builder else { return }
        state = .finished

        stopDisplayTimer()
        persistTimer?.invalidate()
        persistTimer = nil
        isRouteRecording = false
        locationMgr?.stopUpdatingLocation()

        let endDate = Date()
        session.end()

        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                builder.endCollection(withEnd: endDate) { _, err in
                    err != nil ? c.resume(throwing: err!) : c.resume()
                }
            }
            let workout: HKWorkout = try await withCheckedThrowingContinuation { c in
                builder.finishWorkout { w, err in
                    if let err { c.resume(throwing: err) }
                    else if let w { c.resume(returning: w) }
                    else { c.resume(throwing: NSError(domain: "WorkoutManager", code: -1)) }
                }
            }
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    routeBuilder?.finishRoute(with: workout, metadata: nil) { _, err in
                        err != nil ? c.resume(throwing: err!) : c.resume()
                    }
                }
                logger.info("Route saved successfully")
            } catch {
                logger.error("finishRoute failed: \(error.localizedDescription)")
                // Workout is still saved; only the GPS route is missing.
            }

            // Send GPS points directly to iPhone via WatchConnectivity.
            // This bypasses the HealthKit Watch→iPhone sync delay (1–5 min) so the
            // route appears in LoxBridge immediately. The workoutUUID is the same as
            // the HealthKit workout, so the HealthKit observer path will skip it
            // automatically once this direct transfer has been processed.
            sendDirectTransfer(workout: workout)
            try? FileManager.default.removeItem(at: partialRouteURL)

        } catch {
            logger.error("stop() failed: \(error.localizedDescription)")
        }
    }

    private func sendDirectTransfer(workout: HKWorkout) {
        guard WCSession.isSupported() else {
            logger.warning("WCSession not supported on this device")
            return
        }
        let wcs = WCSession.default
        logger.info("WCSession state before transfer — activation: \(wcs.activationState.rawValue), reachable: \(wcs.isReachable), pendingTransfers: \(wcs.outstandingFileTransfers.count)")
        guard wcs.activationState == .activated else {
            logger.warning("WCSession not activated (state=\(wcs.activationState.rawValue)) — iPhone will fall back to HealthKit sync")
            return
        }
        guard !allRecordedLocations.isEmpty else {
            logger.warning("No recorded locations to transfer")
            return
        }

        let points: [[Double]] = allRecordedLocations.map { loc in
            [loc.coordinate.latitude,
             loc.coordinate.longitude,
             loc.timestamp.timeIntervalSince1970,
             max(0, loc.speed),
             loc.horizontalAccuracy]
        }

        let deviceName: String = {
            if let name = workout.device?.name, let type = workout.sourceRevision.productType {
                return "\(name) (\(type))"
            }
            return workout.device?.name ?? workout.sourceRevision.source.name
        }()

        let transfer = WatchGPSTransfer(
            workoutUUID:      workout.uuid.uuidString,
            startDate:        workout.startDate.timeIntervalSince1970,
            durationSeconds:  workout.duration,
            distanceMeters:   distanceMeters,
            activityTypeName: "Running",
            deviceName:       deviceName,
            points:           points
        )

        do {
            let data = try JSONEncoder().encode(transfer)
            if wcs.isReachable {
                // iPhone is reachable — use sendMessageData for immediate in-memory delivery.
                // This works in both simulator and foreground/background scenarios on device.
                // transferFile is a background-only mechanism and is not delivered while both
                // apps are actively running (and is unreliable in the simulator entirely).
                wcs.sendMessageData(data, replyHandler: { _ in
                    logger.info("GPS sendMessageData acknowledged by iPhone: \(transfer.workoutUUID)")
                }, errorHandler: { error in
                    logger.warning("GPS sendMessageData failed (\(error.localizedDescription)) — falling back to transferFile")
                    self.queueFileTransfer(data: data, uuid: transfer.workoutUUID)
                })
                logger.info("GPS sent via sendMessageData: \(points.count) points for \(workout.uuid.uuidString)")
            } else {
                // iPhone not reachable — queue via transferFile for background delivery.
                queueFileTransfer(data: data, uuid: workout.uuid.uuidString)
            }
        } catch {
            logger.error("Failed to encode GPS transfer: \(error.localizedDescription)")
        }

        // Insert a provisional route entry on the Watch immediately so the user
        // sees "Sending to iPhone…" in the list while the transfer is in flight.
        // The iPhone will replace this entry with a real status once it processes the workout.
        lastFinishedUUID = workout.uuid.uuidString
        let provisional = WatchRoutePayload(
            workoutUUID:      workout.uuid.uuidString,
            status:           "Sending to iPhone\u{2026}",
            distanceKm:       distanceMeters > 0 ? distanceMeters / 1000.0 : nil,
            durationSeconds:  workout.duration > 0 ? workout.duration : Double(elapsedSeconds),
            activityTypeName: "Running",
            locationName:     nil,
            createdAt:        workout.startDate.timeIntervalSince1970,
            points:           [],
            speeds:           nil
        )
        WatchSessionManager.shared.insertProvisionalRoute(provisional)
    }

    /// Writes `data` to a temp file and queues it via WCSession.transferFile.
    /// Used when the iPhone is not currently reachable (background delivery).
    private func queueFileTransfer(data: Data, uuid: String) {
        do {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("gps_\(uuid).json")
            try data.write(to: tmpURL)
            let ft = WCSession.default.transferFile(tmpURL, metadata: ["type": "WatchGPSTransfer"])
            logger.info("GPS queued via transferFile: \(uuid), isTransferring=\(ft.isTransferring)")
        } catch {
            logger.error("Failed to queue GPS file transfer: \(error.localizedDescription)")
        }
    }

    func reset() {
        session      = nil
        builder      = nil
        routeBuilder = nil
        locationMgr  = nil
        elapsedSeconds       = 0
        distanceMeters       = 0
        errorMessage         = nil
        lastFinishedUUID     = nil
        currentGPSAccuracy   = -1
        state                = .idle
        isWorkoutOpen        = false
        allRecordedLocations = []
        persistTimer?.invalidate()
        persistTimer = nil
        // Restart idle GPS monitor so the accuracy icon is live again.
        startIdleLocationUpdates()
    }

    // MARK: - Private

    private func requestAuthorization() async throws {
        // HKSeriesType.workoutRoute() MUST be in shareTypes — without it,
        // insertRouteData and finishRoute silently succeed but write nothing,
        // and the workout has no GPS route in HealthKit.
        let shareTypes: Set<HKSampleType> = [
            .workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKSeriesType.workoutRoute(),
        ]
        try await healthStore.requestAuthorization(toShare: shareTypes, read: shareTypes)
    }

    private func beginSession() async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                      workoutConfiguration: config)
        session.delegate = self
        builder.delegate = self

        self.session      = session
        self.builder      = builder
        self.routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)

        let start = Date()
        session.startActivity(with: start)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: start) { _, err in
                err != nil ? c.resume(throwing: err!) : c.resume()
            }
        }

        partialSessionUUID = UUID()
        isRouteRecording = true   // must be set before startLocationUpdates()
        startLocationUpdates()
        startDisplayTimer()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.savePartialRoute()
            }
        }
    }

    private func startLocationUpdates() {
        let mgr = CLLocationManager()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.distanceFilter  = 5
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        locationMgr = mgr
    }

    private func startDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // DispatchQueue.main.async avoids "Publishing changes from within view
            // updates" — unlike Task { @MainActor }, it always defers to the next
            // run loop iteration rather than potentially executing synchronously.
            DispatchQueue.main.async { [weak self] in
                guard let self, let b = self.builder else { return }
                self.elapsedSeconds = Int(b.elapsedTime)
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - Partial route persistence

    private var partialRouteURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("partial_route_\(partialSessionUUID.uuidString).json")
    }

    private func savePartialRoute() {
        guard !allRecordedLocations.isEmpty else { return }
        let points: [[Double]] = allRecordedLocations.map { loc in
            [loc.coordinate.latitude,
             loc.coordinate.longitude,
             loc.timestamp.timeIntervalSince1970,
             max(0, loc.speed),
             loc.horizontalAccuracy]
        }
        let startTime = allRecordedLocations.first?.timestamp.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let transfer = WatchGPSTransfer(
            workoutUUID: partialSessionUUID.uuidString,
            startDate: startTime,
            durationSeconds: Double(elapsedSeconds),
            distanceMeters: distanceMeters,
            activityTypeName: "Running",
            deviceName: WKInterfaceDevice.current().name,
            points: points
        )
        do {
            let data = try JSONEncoder().encode(transfer)
            try data.write(to: partialRouteURL)
        } catch {
            logger.error("Failed to save partial route: \(error.localizedDescription)")
        }
    }

    private func checkForPartialRecovery() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else { return }
        let partialFiles = files.filter { $0.lastPathComponent.hasPrefix("partial_route_") }
        partialRecoveryURLs = partialFiles
        hasPartialRecovery = !partialFiles.isEmpty
        if !partialFiles.isEmpty {
            logger.info("Found \(partialFiles.count) partial route file(s) for recovery")
        }
    }

    func recoverPartialRoute() {
        guard let url = partialRecoveryURLs.first else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            logger.warning("WCSession not ready — try again in a moment")
            return
        }
        do {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: tmpURL.path) {
                try FileManager.default.removeItem(at: tmpURL)
            }
            try FileManager.default.copyItem(at: url, to: tmpURL)
            WCSession.default.transferFile(tmpURL, metadata: ["type": "WatchGPSTransfer"])
            try? FileManager.default.removeItem(at: url)
            partialRecoveryURLs.removeFirst()
            hasPartialRecovery = !partialRecoveryURLs.isEmpty
            logger.info("Recovery transfer queued: \(url.lastPathComponent)")
        } catch {
            logger.error("Recovery transfer failed: \(error.localizedDescription)")
        }
    }

    func discardPartialRoute() {
        for url in partialRecoveryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        partialRecoveryURLs = []
        hasPartialRecovery = false
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ session: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState,
                                    date: Date) {
        // DispatchQueue.main.async always defers to the next run loop iteration,
        // preventing "Publishing changes from within view updates" faults that
        // Task { @MainActor in } can cause by executing synchronously.
        DispatchQueue.main.async { [weak self] in
            switch toState {
            case .running: self?.state = .active
            case .paused:  self?.state = .paused
            default:       break
            }
        }
    }

    nonisolated func workoutSession(_ session: HKWorkoutSession,
                                    didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType(.distanceWalkingRunning)) else { return }
        let meters = workoutBuilder
            .statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
        DispatchQueue.main.async { [weak self] in self?.distanceMeters = meters }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - CLLocationManagerDelegate

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in self?.locationAuthStatus = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Always update the GPS accuracy indicator for the idle screen,
            // regardless of which manager fired (idle or workout).
            if latest.horizontalAccuracy > 0 {
                self.currentGPSAccuracy = latest.horizontalAccuracy
            }

            // Route recording: only feed points from the workout location manager
            // while isRouteRecording is active.
            guard self.isRouteRecording else { return }
            let accurate = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 50 }
            guard !accurate.isEmpty else { return }
            self.allRecordedLocations.append(contentsOf: accurate)
            self.routeBuilder?.insertRouteData(accurate) { _, err in
                if let err {
                    logger.error("insertRouteData failed: \(err.localizedDescription)")
                }
            }
        }
    }
}
