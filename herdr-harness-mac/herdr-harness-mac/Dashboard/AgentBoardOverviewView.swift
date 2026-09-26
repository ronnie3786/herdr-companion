import SwiftUI

struct AgentBoardOverviewView: View {
    let content: AgentBoardContent
    let showAgents: () -> Void
    let openAgent: (AgentBoardContent.AgentRow) -> Void
    @State private var goalExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    DashboardMicroLabel(text: "Goal")
                    Text(content.goal.isEmpty ? "No goal added yet." : content.goal)
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(content.goal.isEmpty ? HerdrTheme.tertiaryText : HerdrTheme.secondaryText)
                        .lineSpacing(4)
                        .lineLimit(goalExpanded ? nil : 4)
                        .textSelection(.enabled)
                    if content.goal.count > 220 {
                        Button(goalExpanded ? "Show less" : "Show more") { goalExpanded.toggle() }
                            .buttonStyle(.plain)
                            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                            .foregroundStyle(HerdrTheme.accent)
                            .frame(minHeight: HerdrTheme.minHitTarget)
                            .contentShape(.rect)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DashboardMicroLabel(text: "Agents")
                        Spacer()
                        if content.agents.count > 3 {
                            Button("View all \(content.agents.count)", action: showAgents)
                                .buttonStyle(.plain)
                                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                                .foregroundStyle(HerdrTheme.accent)
                                .frame(minHeight: HerdrTheme.minHitTarget)
                                .contentShape(.rect)
                        }
                    }
                    if content.agents.isEmpty {
                        Text("No agents assigned yet.").herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                    VStack(spacing: 0) {
                        ForEach(content.agents.prefix(3)) { agent in
                            AgentBoardAgentRow(agent: agent, open: { openAgent(agent) })
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    DashboardMicroLabel(text: "Journal")
                    if content.latestNotes.isEmpty {
                        Text("Progress and decisions will appear here.")
                            .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                    VStack(spacing: 0) {
                        ForEach(content.latestNotes) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(note.text)
                                    .herdrFont(size: HerdrTheme.TextSize.small)
                                    .foregroundStyle(HerdrTheme.primaryText)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                if let date = note.date {
                                    DashboardAgeText(date: date)
                                        .herdrFont(size: HerdrTheme.TextSize.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(HerdrTheme.tertiaryText)
                                }
                            }
                            .frame(minHeight: 26)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
