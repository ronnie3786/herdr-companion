import SwiftUI

struct FirstMateAgentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your crew").font(.title2).bold().accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("first-mate-agents")
                Text("\(snapshot.assignments.count) \(snapshot.assignments.count == 1 ? "assignment" : "assignments"), grouped by the step they belong to. Open an agent to see its saved session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !snapshot.sessions(for: nil).isEmpty {
                FirstMateCoordinatorHistoryView(store: store, sessions: snapshot.sessions(for: nil))
            }
            ForEach(snapshot.visits.filter { !snapshot.agents(for: $0.id).isEmpty }) { visit in
                FirstMateAgentGroup(store: store, snapshot: snapshot, visit: visit,
                                    initiallyExpanded: visit.id == (store.selectedVisitID ?? snapshot.feature.currentVisitID))
            }
            if snapshot.assignments.isEmpty {
                ContentUnavailableView("No agents assigned yet", systemImage: "person.2", description: Text("Discuss the plan in the feature conversation to get started."))
            }
            if snapshot.sessionsTruncated {
                Text("Showing the newest \(snapshot.sessions.count) saved \(snapshot.sessions.count == 1 ? "session" : "sessions"). Earlier sessions remain retained on the companion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
