import Foundation

/// Data transferred from iPhone to Watch via WatchConnectivity.
/// Must be kept in sync with the identical file in the LoxBrige (iPhone) target.
struct WatchRoutePayload: Codable, Identifiable {
    var id: String { workoutUUID }
    let workoutUUID: String
    let status: String
    let distanceKm: Double?
    let durationSeconds: Double?
    let activityTypeName: String?
    let locationName: String?
    let createdAt: TimeInterval?
    let points: [[Double]]          // [[lat, lon], …] up to 200 points
    let speeds: [Double]?           // normalized 0 (slow) … 1 (fast), same count as points
}
