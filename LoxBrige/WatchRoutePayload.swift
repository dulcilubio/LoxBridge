import Foundation

/// Data transferred from iPhone to Watch via WatchConnectivity.
/// `[[Double]]` for points instead of `[CLLocationCoordinate2D]` because
/// WCSession.updateApplicationContext requires plist-compatible values.
struct WatchRoutePayload: Codable, Identifiable {
    var id: String { workoutUUID }
    let workoutUUID: String
    let status: String              // "On Livelox", "Processing…", "Saved", "Failed"
    let distanceKm: Double?
    let durationSeconds: Double?
    let activityTypeName: String?
    let locationName: String?
    let createdAt: TimeInterval?    // Date.timeIntervalSince1970
    let points: [[Double]]          // [[lat, lon], …] up to 200 points
    let speeds: [Double]?           // normalized 0 (slow) … 1 (fast), same count as points
}
