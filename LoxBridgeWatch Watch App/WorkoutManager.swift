import Combine
import HealthKit
import CoreLocation
import WatchConnectivity
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

    private let healthStore  = HKHealthStore()
    private var session:     HKWorkoutSession?
    private var builder:     HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var locationMgr: CLLocationManager?
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

    private override init() { super.init() }

    // MARK: - Public API

    func start() async {
        do {
            try await requestAuthorization()
            try await beginSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        guard let session else { return }
        state == .active ? session.pause() : session.resume()
    }

    func stop() async {
        guard let session, let builder else { return }
        stopDisplayTimer()
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

        } catch {
            logger.error("stop() failed: \(error.localizedDescription)")
        }

        state = .finished
    }

    private func sendDirectTransfer(workout: HKWorkout) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            logger.warning("WCSession not available — iPhone will fall back to HealthKit sync")
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
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("gps_\(workout.uuid.uuidString).json")
            try data.write(to: tmpURL)
            WCSession.default.transferFile(tmpURL, metadata: ["type": "WatchGPSTransfer"])
            logger.info("GPS transfer queued: \(points.count) points for \(workout.uuid.uuidString)")
        } catch {
            logger.error("Failed to queue GPS transfer: \(error.localizedDescription)")
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

    func reset() {
        session      = nil
        builder      = nil
        routeBuilder = nil
        locationMgr  = nil
        elapsedSeconds   = 0
        distanceMeters   = 0
        errorMessage     = nil
        lastFinishedUUID = nil
        state            = .idle
        allRecordedLocations = []
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

        isRouteRecording = true   // must be set before startLocationUpdates()
        startLocationUpdates()
        startDisplayTimer()
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
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ session: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak self] in
            switch toState {
            case .running: self?.state = .active
            case .paused:  self?.state = .paused
            default:       break
            }
        }
    }

    nonisolated func workoutSession(_ session: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor [weak self] in
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
        Task { @MainActor [weak self] in self?.distanceMeters = meters }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - CLLocationManagerDelegate

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let accurate = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 50 }
        guard !accurate.isEmpty else { return }
        Task { @MainActor [weak self] in
            // Use isRouteRecording (set synchronously in beginSession) rather than
            // state == .active: the HKWorkoutSession .running delegate callback is
            // async and often arrives after the first location batches, so checking
            // state would silently drop those early GPS points.
            guard let self, self.isRouteRecording else { return }
            self.allRecordedLocations.append(contentsOf: accurate)
            self.routeBuilder?.insertRouteData(accurate) { _, err in
                if let err {
                    logger.error("insertRouteData failed: \(err.localizedDescription)")
                }
            }
        }
    }
}
