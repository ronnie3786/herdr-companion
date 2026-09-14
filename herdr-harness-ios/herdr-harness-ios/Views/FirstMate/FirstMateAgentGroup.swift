import SwiftUI

struct FirstMateAgentGroup: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @State private var isExpanded: Bool
    @Environment(\.colorScheme) private var scheme

    init(store: FirstMateStore, snapshot: FirstMateSnapshot, visit: FirstMateVisit, initiallyExpanded: Bool) {
        self.store = store
        self.snapshot = snapshot
        self.visit = visit
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var agents: [FirstMateAssignment] { snapshot.agents(for: visit.id) }
    private var completed: Int { agents.filter { ["complete", "completed", "passed"].contains($0.status) }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                ForEach(agents) { agent in
                    FirstMateAgentRow(store: store, agent: agent)
                }
            }
            .padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(visit.title).font(.headline)
                    .accessibilityIdentifier("first-mate-agent-group-\(visit.id)")
                Text("\(agents.count) \(agents.count == 1 ? "agent" : "agents") · \(completed) complete")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .padding(16)
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 18))
    }
}
