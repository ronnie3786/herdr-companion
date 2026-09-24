import SwiftUI

struct AgentBoardAgentsView: View {
    @Bindable var state: AgentBoardColumnState
    let snapshot: FirstMateSnapshot
    let openLiveSession: (String) -> Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !snapshot.coordinatorSessions.isEmpty {
                    Text("First Mate sessions").herdrFont(.subheadline, weight: .medium)
                        .foregroundStyle(HerdrTheme.muted).accessibilityAddTraits(.isHeader)
                    ForEach(snapshot.coordinatorSessions.reversed()) { session in
                        Button {
                            if !openLiveSession(session.nativeSessionID) {
                                Task { await state.resources.open(.history(session)) }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sailboat").foregroundStyle(HerdrTheme.accent)
                                Text(session.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                                Image(systemName: "arrow.up.right").foregroundStyle(HerdrTheme.accent)
                            }
                            .herdrFont(.body)
                            .padding(12)
                            .background(HerdrTheme.graphite, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open First Mate session \(session.title)")
                    }
                }
                Text("Agents").herdrFont(.subheadline, weight: .medium)
                    .foregroundStyle(HerdrTheme.muted).accessibilityAddTraits(.isHeader)
                    .padding(.top, snapshot.coordinatorSessions.isEmpty ? 0 : 8)
                if snapshot.assignments.isEmpty {
                    Text("No agents assigned yet. First Mate will add them as the plan takes shape.")
                        .herdrFont(.body).foregroundStyle(HerdrTheme.muted)
                }
                ForEach(snapshot.assignments) { agent in
                    AgentBoardAssignmentView(state: state, agent: agent, openLiveSession: openLiveSession)
                }
                if snapshot.sessionsTruncated {
                    Text("Earlier sessions remain available in the full First Mate view.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
