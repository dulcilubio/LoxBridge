import SwiftUI
import UIKit
import HealthKit

/// Troubleshooting screen: shows what LoxBridge can see in Health and why each recent
/// workout is or isn't in the route list. Missing workouts with a GPS route can be imported.
struct WorkoutDiagnosticsView: View {
    @State private var report: WorkoutDiagnosticsReport?
    @State private var importing: Set<UUID> = []
    @State private var importCandidate: DiagnosedWorkout?
    @State private var importError: String?

    private let diagnostics = WorkoutDiagnostics()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            if let report {
                healthSection(report)
                workoutsSection(report)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Reading workouts from Health…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Missing workouts?")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "Import this workout?",
            isPresented: Binding(
                get: { importCandidate != nil },
                set: { if !$0 { importCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: importCandidate
        ) { item in
            Button("Import") {
                Task { await importWorkout(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The route will be saved in LoxBridge and uploaded to Livelox according to your settings. If it was already uploaded earlier, it may appear twice in Livelox.")
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Sections

    private func healthSection(_ report: WorkoutDiagnosticsReport) -> some View {
        Section {
            LabeledContent("Health available") {
                Text(report.healthDataAvailable ? String(localized: "Yes") : String(localized: "No"))
            }
            LabeledContent("Access requested") {
                Text(report.accessRequested ? String(localized: "Yes") : String(localized: "No"))
            }
            LabeledContent("Workouts found", value: "\(report.workoutCount)")
            LabeledContent("With GPS route", value: "\(report.routeCount)")
            Button("Open Health App Settings") {
                if let url = URL(string: "x-apple-health://sources") {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Health (last 30 days)")
        } footer: {
            Text("iOS does not tell apps whether read access was denied — denied data simply looks empty. If workouts you can see in the Fitness app are missing here, open Health → Profile → Apps → LoxBridge and turn on Workouts and Workout Routes.")
        }
    }

    @ViewBuilder
    private func workoutsSection(_ report: WorkoutDiagnosticsReport) -> some View {
        Section {
            if report.workouts.isEmpty {
                Text("No workouts found in Health for the last 30 days.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.workouts) { item in
                    row(item)
                }
            }
        } header: {
            Text("Workouts")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workouts that are missing for a reason you can override, and that have a GPS route, can be imported manually.")
                Text("Some third-party apps save workouts to Health without the GPS route. Those workouts can't be imported.")
            }
        }
    }

    private func row(_ item: DiagnosedWorkout) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(item.activityName) · \(Self.dateFormatter.string(from: item.workout.startDate))")
                    .font(.subheadline)
                Text(item.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(item.status.label, systemImage: icon(for: item.status))
                    .font(.caption)
                    .foregroundStyle(color(for: item.status))
            }
            Spacer(minLength: 0)
            if importing.contains(item.id) {
                ProgressView()
            } else if item.canImport {
                Button("Import") {
                    importCandidate = item
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func icon(for status: WorkoutDiagnosticStatus) -> String {
        switch status {
        case .uploaded:   return "checkmark.circle.fill"
        case .saved:      return "tray.full"
        case .notOutdoor: return "figure.indoor.cycle"
        case .noRoute:    return "location.slash"
        default:          return "exclamationmark.circle"
        }
    }

    private func color(for status: WorkoutDiagnosticStatus) -> Color {
        switch status {
        case .uploaded, .saved:     return .green
        case .notOutdoor, .noRoute: return .secondary
        default:                    return .orange
        }
    }

    // MARK: - Actions

    private func reload() async {
        report = await diagnostics.run()
    }

    private func importWorkout(_ item: DiagnosedWorkout) async {
        importing.insert(item.id)
        defer { importing.remove(item.id) }
        do {
            try await WorkoutProcessor.shared.importManually(workout: item.workout)
        } catch {
            importError = error.localizedDescription
        }
        await reload()
    }
}

#Preview {
    NavigationStack {
        WorkoutDiagnosticsView()
    }
}
