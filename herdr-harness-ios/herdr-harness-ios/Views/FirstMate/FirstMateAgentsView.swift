import SwiftUI

struct FirstMateAgentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FirstMateInspectorHeading(title: "Your crew",
                detail: "\(snapshot.assignments.count) \(snapshot.assignments.count == 1 ? "assignment" : "assignments"), each with its own session and evidence.")
                .accessibilityIdentifier("first-mate-agents")
            if !snapshot.coordinatorSessions.isEmpty {
                FirstMateCoordinatorHistoryView(store: store, sessions: snapshot.coordinatorSessions)
            }
            if !snapshot.advisorSessions.isEmpty {
                FirstMateCoordinatorHistoryView(
                    store: store,
                    sessions: snapshot.advisorSessions,
                    title: "Advisors",
                    symbol: "lifepreserver",
                    accessibilityID: "first-mate-advisor-history"
                )
            }
            VStack(spacing: 0) {
                ForEach(snapshot.visits.filter { !snapshot.agents(for: $0.id).isEmpty }) { visit in
                    FirstMateAgentGroup(store: store, snapshot: snapshot, visit: visit,
                                        initiallyExpanded: visit.id == (store.selectedVisitID ?? snapshot.feature.currentVisitID))
                }
            }
            if snapshot.assignments.isEmpty {
                ContentUnavailableView("No agents assigned yet", systemImage: "person.2", description: Text("Discuss the plan in the feature conversation to get started."))
            }
            if snapshot.sessionsTruncated {
                Text("Showing the newest \(snapshot.sessions.count) saved \(snapshot.sessions.count == 1 ? "session" : "sessions"). Earlier sessions remain retained on the companion.")
                    .font(.footnote)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
    }
}
