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
                    if content.goalBlocks.isEmpty {
                        Text("No goal added yet.")
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    } else {
                        AgentBoardProseView(blocks: content.goalBlocks)
                            .frame(maxHeight: goalExpanded || !content.canExpandGoal ? nil : 88, alignment: .top)
                            .clipped()
                    }
                    if content.canExpandGoal {
                        Button(goalExpanded ? "Show less" : "Show more") { goalExpanded.toggle() }
                            .buttonStyle(.herdrPlain)
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
                                .buttonStyle(.herdrPlain)
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
                                AgentBoardProseView(blocks: note.blocks, textColor: HerdrTheme.primaryText)
                                    .lineLimit(3)
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
