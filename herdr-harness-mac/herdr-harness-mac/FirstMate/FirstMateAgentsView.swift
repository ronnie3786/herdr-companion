import SwiftUI

struct FirstMateAgentsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your crew").herdrFont(size: 15, weight: .semibold)
            Text("\(FirstMateCountText.phrase(snapshot.assignments.count, "assignment")), each with its own session and evidence.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
            if !snapshot.coordinatorSessions.isEmpty {
                DisclosureGroup("Second Mate · Feature lead · \(FirstMateCountText.phrase(snapshot.coordinatorSessions.count, "saved session"))") {
                    ForEach(snapshot.coordinatorSessions) { session in
                        FirstMateSessionRow(store: store, session: session)
                    }
                }
                .accessibilityIdentifier("first-mate-coordinator-history")
                Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            }
            if !snapshot.advisorSessions.isEmpty {
                DisclosureGroup("Advisors · \(FirstMateCountText.phrase(snapshot.advisorSessions.count, "saved session"))") {
                    ForEach(snapshot.advisorSessions) { session in
                        FirstMateSessionRow(store: store, session: session)
                    }
                }
                .accessibilityIdentifier("first-mate-advisor-history")
                Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            }
            ForEach(snapshot.visits.filter { !snapshot.agents(for: $0.id).isEmpty }) { visit in
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(snapshot.agents(for: visit.id)) { agent in FirstMateAgentRow(store: store, agent: agent) }
                    }.padding(.top, 4)
                } label: {
                    HStack {
                        Text(visit.title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        Spacer()
                        Text(FirstMateCountText.phrase(snapshot.agents(for: visit.id).count, "agent")).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                .accessibilityIdentifier("first-mate-agent-group-\(visit.id)")
                Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            }
            if snapshot.assignments.isEmpty {
                ContentUnavailableView("No agents assigned yet", systemImage: "person.2", description: Text("Discuss the plan in the feature conversation to get started."))
            }
            if snapshot.sessionsTruncated {
                Text("Showing the newest \(snapshot.sessions.count) saved sessions. Earlier sessions remain retained on the companion.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
        }
    }
}
