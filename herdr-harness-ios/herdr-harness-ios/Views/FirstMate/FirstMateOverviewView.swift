import SwiftUI

struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme

    private var currentAgents: [FirstMateAssignment] {
        snapshot.currentVisit.map { snapshot.agents(for: $0.id) } ?? []
    }

    /// The same journal milestones as Mac Overview, including First Mate's
    /// private notes from background work; bookkeeping stays in the activity log.
    private var latestMilestones: [FirstMateEvent] {
        Array(snapshot.events.filter(\.isMilestone).sorted { $0.sequence > $1.sequence }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("The goal", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HerdrTheme.accent)
                Text(snapshot.feature.goal)
                    .font(.title3)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("first-mate-overview")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrCard()

            FirstMateVerificationSummaryView(
                verification: snapshot.feature.verification,
                isLastReported: !store.isDemo && store.error != nil
            )
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrCard()

            FirstMateUsageSummaryView(usage: snapshot.feature.usage, title: "Full task usage")
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .herdrCard()

            if let visit = snapshot.currentVisit {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Current focus").font(.headline).accessibilityAddTraits(.isHeader)
                    FirstMateVisitHeading(visit: visit, isCurrent: true, displayStatus: snapshot.displayStatus(for: visit))
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                    if visit.status == "awaiting_direction" {
                        Label("The next step waits for your direction in the conversation.", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline)
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Working on this step").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("See all") { store.inspector = .agents }
                        .font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(snapshot.assignments.count == 1 ? "See the agent" : "See all \(snapshot.assignments.count) agents")
                }
                ForEach(Array(currentAgents.prefix(3))) { agent in
                    FirstMateAgentRow(store: store, agent: agent)
                }
                if currentAgents.count > 3 {
                    Button("\(currentAgents.count - 3) more \(currentAgents.count == 4 ? "agent" : "agents") on this step", systemImage: "person.2") {
                        store.inspector = .agents
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                } else if currentAgents.isEmpty {
                    Text("Your First Mate will assemble the crew when you choose a next step.")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Latest in the journal").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(latestMilestones) { event in
                    FirstMateJournalRow(event: event)
                }
                if latestMilestones.isEmpty {
                    Text("Decisions and progress will appear here as the feature moves forward.")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }
}
