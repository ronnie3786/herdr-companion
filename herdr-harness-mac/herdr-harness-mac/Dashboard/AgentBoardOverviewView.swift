import SwiftUI

struct AgentBoardOverviewView: View {
    @Bindable var state: AgentBoardColumnState
    let snapshot: FirstMateSnapshot
    let openLiveSession: (String) -> Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Goal")
                    Text(snapshot.feature.goal.isEmpty ? "No goal added yet." : snapshot.feature.goal)
                        .herdrFont(.body)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionTitle("Agents")
                        Spacer()
                        if !snapshot.assignments.isEmpty {
                            Button("View all \(snapshot.assignments.count)") { state.tab = .agents }
                                .buttonStyle(.plain)
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.accent)
                        }
                    }
                    if snapshot.assignments.isEmpty {
                        Text("No agents assigned yet.").herdrFont(.body).foregroundStyle(HerdrTheme.muted)
                    }
                    ForEach(Array(snapshot.assignments.prefix(3))) { agent in
                        AgentBoardAssignmentView(state: state, agent: agent, openLiveSession: openLiveSession)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Latest journal")
                    if snapshot.events.isEmpty {
                        Text("Progress and decisions will appear here.")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.muted)
                    }
                    ForEach(Array(snapshot.events.suffix(3).reversed())) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.summary).herdrFont(.body).textSelection(.enabled)
                            if let date = HerdrTimestamp.date(from: event.createdAt) {
                                Text(date, style: .relative).herdrFont(.caption2).foregroundStyle(HerdrTheme.muted)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).herdrFont(.subheadline, weight: .medium).foregroundStyle(HerdrTheme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}
