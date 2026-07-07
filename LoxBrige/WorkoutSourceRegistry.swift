import Foundation
import Observation

struct WorkoutSource: Codable, Identifiable {
    let bundleID: String
    var displayName: String
    var isEnabled: Bool
    let firstSeenAt: Date

    var id: String { bundleID }
    var isBuiltIn: Bool { bundleID.hasPrefix("se.erikfrick.loxbridge") }
}

/// Persists which recording app sources the user has enabled.
/// Sources are discovered automatically the first time a workout from that app
/// is detected in HealthKit — no hardcoded list of apps needed.
@Observable
@MainActor
final class WorkoutSourceRegistry {
    static let shared = WorkoutSourceRegistry()

    private(set) var sources: [WorkoutSource] = []

    var nonBuiltInSources: [WorkoutSource] {
        sources.filter { !$0.isBuiltIn }.sorted { $0.displayName < $1.displayName }
    }

    private let storageKey = "workoutSources"

    private init() {
        load()
    }

    /// Registers a source if not already known. No-op when the source is already in the registry.
    @discardableResult
    func register(bundleID: String, displayName: String) -> Bool {
        guard !sources.contains(where: { $0.bundleID == bundleID }) else { return false }
        sources.append(WorkoutSource(
            bundleID: bundleID,
            displayName: displayName,
            isEnabled: defaultEnabled(for: bundleID),
            firstSeenAt: Date()
        ))
        save()
        return true
    }

    func isEnabled(bundleID: String) -> Bool {
        sources.first { $0.bundleID == bundleID }?.isEnabled ?? false
    }

    func setEnabled(bundleID: String, enabled: Bool) {
        guard let i = sources.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        sources[i].isEnabled = enabled
        save()
    }

    // MARK: - Private

    /// Default enabled state for a newly discovered source.
    /// Apple bundle IDs inherit the legacy `uploadFitnessAppRoutes` preference (default: true).
    /// Everything else starts disabled — the user must opt in explicitly.
    private func defaultEnabled(for bundleID: String) -> Bool {
        guard bundleID.hasPrefix("com.apple.") else { return false }
        if UserDefaults.standard.object(forKey: "uploadFitnessAppRoutes") != nil {
            return UserDefaults.standard.bool(forKey: "uploadFitnessAppRoutes")
        }
        return true
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WorkoutSource].self, from: data)
        else { return }
        sources = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
