import SwiftUI

struct FirstMateReliabilityView: View {
    let health: FirstMateRuntimeHealth?
    let snapshot: FirstMateSnapshot

    private var history: [FirstMateEvent] {
        snapshot.events.filter { $0.featureID == snapshot.feature.id && $0.type.hasPrefix("reliability.") }
            .sorted { $0.sequence > $1.sequence }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stability & recovery", systemImage: "heart.text.clipboard")
                .herdrFont(.headline)
            if let enabled = health?.automaticRecovery {
                Text(enabled ? "Automatic recovery is enabled within the current authorized stage." : "Automatic recovery is disabled on this companion.")
                    .herdrFont(.caption)
                if let guardianAlive = health?.guardianAlive {
                    Label(guardianAlive ? "Scheduler guardian active" : "Scheduler guardian is not running",
                          systemImage: guardianAlive ? "checkmark.shield" : "exclamationmark.shield")
                        .herdrFont(.caption)
                }
                if let seconds = health?.sweepIntervalSeconds {
                    Text("Stale-progress check every \(seconds / 60) minutes. A live process alone is not proof of progress.")
                        .herdrFont(.caption).foregroundStyle(.secondary)
                }
                if let last = health?.lastSweepAt {
                    Text("Last sweep: \(last)").herdrFont(.caption2).foregroundStyle(.secondary)
                }
                if enabled, let next = health?.nextSweepAt {
                    Text("Next sweep: \(next)").herdrFont(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Update the companion server and Pi package for automatic stability checks.")
                    .herdrFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.assignments.filter { $0.metadata?.progress != nil }) { assignment in
                if let progress = assignment.metadata?.progress {
                    DisclosureGroup("Progress checkpoint · \(assignment.title)") {
                        FirstMateProgressView(progress: progress).padding(.top, 8)
                    }
                    .herdrFont(.subheadline)
                }
            }
            if !history.isEmpty {
                DisclosureGroup("Recovery history · \(history.count) events") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(history.prefix(30)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.summary).herdrFont(.subheadline)
                                Text(event.createdAt).herdrFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if history.count > 30 {
                            Text("Showing the latest 30 actions; earlier events remain in the server journal.")
                                .herdrFont(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }
                .herdrFont(.subheadline)
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("first-mate-stability")
    }
}
