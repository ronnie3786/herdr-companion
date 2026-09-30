import SwiftUI

/// The Mac inspector's Overview, sized for touch: "The feature at a glance",
/// the goal, usage and current focus cards, the step's agents as plain rows,
/// and the latest journal milestones.
struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    private var currentAgents: [FirstMateAssignment] {
        snapshot.currentVisit.map { snapshot.agents(for: $0.id) } ?? []
    }

    /// The same journal milestones as Mac Overview, including First Mate's
    /// private notes from background work; bookkeeping stays in the activity log.
    private var latestMilestones: [FirstMateEvent] {
        Array(snapshot.events.filter(\.isMilestone).sorted { $0.sequence > $1.sequence }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FirstMateInspectorHeading(title: "The feature at a glance")

            VStack(alignment: .leading, spacing: 6) {
                HerdrMicroLabel(text: "Goal")
                Text(snapshot.feature.goal)
                    .herdrFont(.body).foregroundStyle(HerdrTheme.proseText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("first-mate-overview")
            }

            VStack(alignment: .leading, spacing: 12) {
                FirstMateUsageSummaryView(usage: snapshot.feature.usage, title: "Full task usage")
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()

                if snapshot.feature.verification != nil {
                    FirstMateVerificationSummaryView(
                        verification: snapshot.feature.verification,
                        isLastReported: !store.isDemo && store.error != nil
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()
                }

                if let visit = snapshot.currentVisit {
                    VStack(alignment: .leading, spacing: 0) {
                        HerdrMicroLabel(text: "Current focus")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(visit.title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            FirstMateStatusLabel(status: snapshot.displayStatus(for: visit))
                        }
                        .padding(.top, 8)
                        FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                        if visit.status == "awaiting_direction" {
                            Text("The next step waits for your direction in the conversation.")
                                .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HerdrMicroLabel(text: "Agents")
                    Spacer(minLength: 8)
                    if !snapshot.assignments.isEmpty {
                        Button(snapshot.assignments.count == 1 ? "View agent" : "View all \(snapshot.assignments.count)") {
                            store.inspector = .agents
                        }
                        .buttonStyle(.herdrPlain)
                        .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                        .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                        .accessibilityLabel(snapshot.assignments.count == 1 ? "See the agent" : "See all \(snapshot.assignments.count) agents")
                    }
                }
                let shown = Array(currentAgents.prefix(3))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                    FirstMateAgentRow(store: store, agent: agent, style: .compact, showsDivider: index < shown.count - 1)
                }
                if currentAgents.count > 3 {
                    Button("\(currentAgents.count - 3) more \(currentAgents.count == 4 ? "agent" : "agents") on this step") {
                        store.inspector = .agents
                    }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: 44)
                } else if currentAgents.isEmpty {
                    Text(snapshot.assignments.isEmpty ? "Your First Mate will assemble the crew when work is authorized."
                         : "No agents are working on this step.")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HerdrMicroLabel(text: "Latest in the journal").padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(latestMilestones) { event in
                        FirstMateJournalRow(event: event)
                    }
                    if latestMilestones.isEmpty {
                        Text("Decisions and progress will appear here as the feature moves forward.")
                            .herdrFont(.subheadline).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: 44).contentShape(.rect)
            }
        }
    }
}
