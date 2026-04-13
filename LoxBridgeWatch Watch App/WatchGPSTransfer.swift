import Foundation

/// Payload sent directly from the Watch app to the iPhone via WCSession.transferFile()
/// when a workout ends. This bypasses the HealthKit Watch→iPhone sync delay (1–5 min)
/// so routes appear in LoxBridge and Livelox immediately after the workout.
///
/// The workoutUUID matches the HKWorkout.uuid saved to HealthKit, so the HealthKit
/// observer path (which serves as fallback) will skip this workout automatically
/// once it has been processed here.
struct WatchGPSTransfer: Codable {
    /// HKWorkout.uuid — used as dedup key against processedWorkouts.
    let workoutUUID: String
    let startDate: TimeInterval       // workout.startDate.timeIntervalSince1970
    let durationSeconds: Double
    let distanceMeters: Double
    let activityTypeName: String
    let deviceName: String
    /// Each element: [latitude, longitude, timestamp_since_1970, speed_ms, horizontalAccuracy]
    let points: [[Double]]
}
