import Combine
import HealthKit
import CoreLocation
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
        } catch {
            logger.error("stop() failed: \(error.localizedDescription)")
        }

        state = .finished
    }

    func reset() {
        session      = nil
        builder      = nil
        routeBuilder = nil
        locationMgr  = nil
        elapsedSeconds = 0
        distanceMeters = 0
        errorMessage   = nil
        state          = .idle
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
            Task { @MainActor [weak self] in
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
            self.routeBuilder?.insertRouteData(accurate) { _, err in
                if let err {
                    logger.error("insertRouteData failed: \(err.localizedDescription)")
                }
            }
        }
    }
}
