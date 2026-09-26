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
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
            if let enabled = health?.automaticRecovery {
                Text(enabled ? "Automatic recovery is enabled within the current authorized stage." : "Automatic recovery is disabled on this companion.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                if let guardianAlive = health?.guardianAlive {
                    Label(guardianAlive ? "Scheduler guardian active" : "Scheduler guardian is not running",
                          systemImage: guardianAlive ? "checkmark.shield" : "exclamationmark.shield")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                }
                if let seconds = health?.sweepIntervalSeconds {
                    Text("Stale-progress check every \(seconds / 60) minutes. A live process alone is not proof of progress.")
                        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                if let last = health?.lastSweepAt {
                    Text("Last sweep: \(last)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                if enabled, let next = health?.nextSweepAt {
                    Text("Next sweep: \(next)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
            } else {
                Text("Update the companion server and Pi package for automatic stability checks.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            ForEach(snapshot.assignments.filter { $0.metadata?.progress != nil }) { assignment in
                if let progress = assignment.metadata?.progress {
                    DisclosureGroup("Progress checkpoint · \(assignment.title)") {
                        FirstMateProgressView(progress: progress).padding(.top, 8)
                    }
                    .herdrFont(size: HerdrTheme.TextSize.small)
                }
            }
            if !history.isEmpty {
                DisclosureGroup("Recovery history · \(history.count) events") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(history.prefix(30)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.summary).herdrFont(size: HerdrTheme.TextSize.small)
                                Text(event.createdAt).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                            }
                        }
                        if history.count > 30 {
                            Text("Showing the latest 30 actions; earlier events remain in the server journal.")
                                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }.padding(.top, 8)
                }
                .herdrFont(size: HerdrTheme.TextSize.small)
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("first-mate-stability")
    }
}
