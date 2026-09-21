import SwiftUI

struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme

    private var currentAgents: [FirstMateAssignment] {
        snapshot.currentVisit.map { snapshot.agents(for: $0.id) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("The goal", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                Text(snapshot.feature.goal)
                    .font(.title3)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("first-mate-overview")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 20))

            FirstMateUsageSummaryView(usage: snapshot.feature.usage, title: "Full task usage")
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 20))

            if let visit = snapshot.currentVisit {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Current focus").font(.headline).accessibilityAddTraits(.isHeader)
                    FirstMateVisitHeading(visit: visit, isCurrent: true)
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                    if visit.status == "awaiting_direction" {
                        Label("The next step waits for your direction in the conversation.", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Latest in the journal").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(snapshot.events.sorted { $0.sequence > $1.sequence }.prefix(3))) { event in
                    FirstMateJournalRow(event: event)
                }
                if snapshot.events.isEmpty {
                    Text("Decisions and progress will appear here as the feature moves forward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }
}
