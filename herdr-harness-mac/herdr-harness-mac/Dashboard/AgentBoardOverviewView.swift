import SwiftUI

struct AgentBoardOverviewView: View {
    let content: AgentBoardContent
    let showAgents: () -> Void
    let openAgent: (AgentBoardContent.AgentRow) -> Void
    @State private var goalExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    DashboardMicroLabel(text: "Goal")
                    Text(content.goal.isEmpty ? "No goal added yet." : content.goal)
                        .herdrFont(.callout)
                        .foregroundStyle(content.goal.isEmpty ? HerdrTheme.muted : HerdrTheme.mist)
                        .lineSpacing(2)
                        .lineLimit(goalExpanded ? nil : 4)
                        .textSelection(.enabled)
                    if content.goal.count > 260 {
                        Button(goalExpanded ? "Show less" : "Show more") { goalExpanded.toggle() }
                            .buttonStyle(.plain).herdrFont(.subheadline).foregroundStyle(HerdrTheme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        DashboardMicroLabel(text: "Agents")
                        Spacer()
                        if content.agents.count > 3 {
                            Button("View all \(content.agents.count)", action: showAgents)
                                .buttonStyle(.plain).herdrFont(.subheadline).foregroundStyle(HerdrTheme.accent)
                        }
                    }
                    if content.agents.isEmpty {
                        Text("No agents assigned yet.").herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                    }
                    ForEach(content.agents.prefix(3)) { agent in
                        AgentBoardAgentRow(agent: agent, open: { openAgent(agent) })
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    DashboardMicroLabel(text: "Journal")
                    if content.latestNotes.isEmpty {
                        Text("Progress and decisions will appear here.")
                            .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                    }
                    ForEach(content.latestNotes) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(note.text)
                                .herdrFont(.callout)
                                .foregroundStyle(HerdrTheme.text)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            if let date = note.date {
                                DashboardAgeText(date: date)
                                    .herdrFont(.subheadline, monospacedDigit: true)
                                    .foregroundStyle(HerdrTheme.muted)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
