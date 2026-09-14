import SwiftUI

struct FirstMateAgentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your crew").herdrFont(.title2, weight: .semibold)
            Text("\(snapshot.assignments.count) assignments, each with its own session and evidence.")
                .herdrFont(.subheadline).foregroundStyle(.secondary)
            if !snapshot.sessions(for: nil).isEmpty {
                DisclosureGroup("First Mate · \(snapshot.sessions(for: nil).count) saved sessions") {
                    ForEach(snapshot.sessions(for: nil)) { session in
                        FirstMateSessionRow(store: store, session: session)
                    }
                }
                .accessibilityIdentifier("first-mate-coordinator-history")
                Divider()
            }
            ForEach(snapshot.visits.filter { !snapshot.agents(for: $0.id).isEmpty }) { visit in
                DisclosureGroup {
                    VStack(spacing: 8) {
                        ForEach(snapshot.agents(for: visit.id)) { agent in FirstMateAgentRow(store: store, agent: agent) }
                    }.padding(.top, 12)
                } label: {
                    HStack {
                        Text(visit.title).herdrFont(.headline)
                        Spacer()
                        Text("\(snapshot.agents(for: visit.id).count) agents").herdrFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("first-mate-agent-group-\(visit.id)")
                Divider()
            }
            if snapshot.assignments.isEmpty {
                ContentUnavailableView("No agents assigned yet", systemImage: "person.2", description: Text("Discuss the plan in the feature conversation to get started."))
            }
            if snapshot.sessionsTruncated {
                Text("Showing the newest \(snapshot.sessions.count) saved sessions. Earlier sessions remain retained on the companion.")
                    .herdrFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
