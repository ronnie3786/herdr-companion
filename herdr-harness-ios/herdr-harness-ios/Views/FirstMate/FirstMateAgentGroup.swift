import SwiftUI

/// One step's crew as a disclosure row with its agent count, divided by a
/// hairline, as in the Mac inspector.
struct FirstMateAgentGroup: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @State private var isExpanded: Bool
    @Environment(\.firstMateHighlightedAssignment) private var highlighted

    init(store: FirstMateStore, snapshot: FirstMateSnapshot, visit: FirstMateVisit, initiallyExpanded: Bool) {
        self.store = store
        self.snapshot = snapshot
        self.visit = visit
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var agents: [FirstMateAssignment] { snapshot.agents(for: visit.id) }
    private var completed: Int { agents.filter { ["complete", "completed", "passed"].contains($0.status) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        FirstMateAgentRow(store: store, agent: agent, showsDivider: index < agents.count - 1)
                    }
                }
                .padding(.leading, 4).padding(.bottom, 6)
            } label: {
                HStack(spacing: 8) {
                    Text(visit.title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                        .accessibilityIdentifier("first-mate-agent-group-\(visit.id)")
                    Spacer(minLength: 8)
                    Text("\(agents.count) \(agents.count == 1 ? "agent" : "agents") · \(completed) complete")
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                }
                .frame(minHeight: HerdrTheme.minHitTarget)
            }
            .tint(HerdrTheme.iconTint)
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
        }
        .onChange(of: highlighted, initial: true) { _, id in
            if agents.contains(where: { $0.id == id }) { isExpanded = true }
        }
    }
}
