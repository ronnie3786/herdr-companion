import SwiftUI

struct AgentBoardAgentsView: View {
    let content: AgentBoardContent
    let openAgent: (AgentBoardContent.AgentRow) -> Void
    let openSession: (FirstMateSession) -> Void
    @State private var showsSessions = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(content.agents.count) agent\(content.agents.count == 1 ? "" : "s") · \(content.runningCount) running")
                    .herdrFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .padding(.bottom, 6)
                if content.agents.isEmpty {
                    Text("No agents assigned yet. First Mate adds them as the plan takes shape.")
                        .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                }
                ForEach(content.agents) { agent in
                    AgentBoardAgentRow(agent: agent, open: { openAgent(agent) })
                }
                if !content.coordinatorSessions.isEmpty {
                    DisclosureGroup(isExpanded: $showsSessions) {
                        ForEach(content.coordinatorSessions) { session in
                            AgentBoardSessionRow(session: session) { openSession(session) }
                        }
                    } label: {
                        Text("First Mate sessions (\(content.coordinatorSessions.count))")
                            .herdrFont(.callout, weight: .medium)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .padding(.top, 12)
                }
                if content.sessionsTruncated {
                    Text("Earlier sessions are in the full First Mate view.")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One line per agent: state glyph, title, status. Role and verdict live in
/// the tooltip so the list stays scannable.
struct AgentBoardAgentRow: View {
    let agent: AgentBoardContent.AgentRow
    let open: () -> Void
    @State private var isHovered = false

    private var glyph: (symbol: String, color: Color) {
        switch agent.statusKind {
        case .running: ("circle.lefthalf.filled", HerdrTheme.signal)
        case .finished: ("checkmark.circle", HerdrTheme.success)
        case .failed: ("xmark.circle", HerdrTheme.attention)
        case .waiting, .other: ("circle", HerdrTheme.muted)
        }
    }

    private var detail: String {
        [agent.roleLabel, agent.verdict].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: glyph.symbol)
                    .imageScale(.small)
                    .foregroundStyle(glyph.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(agent.title)
                    .herdrFont(.callout, weight: .medium)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(agent.statusTitle)
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
                Image(systemName: "arrow.up.right")
                    .imageScale(.small)
                    .foregroundStyle(HerdrTheme.accent)
                    .opacity(isHovered && agent.canOpen ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 30)
            .background(isHovered && agent.canOpen ? HerdrTheme.surface.opacity(0.5) : .clear, in: .rect(cornerRadius: 6))
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!agent.canOpen)
        .onHover { isHovered = $0 }
        .help(detail.isEmpty ? agent.title : "\(agent.title)\n\(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.title), \(agent.statusTitle)")
        .accessibilityHint(agent.canOpen ? "Opens this agent's live chat or saved session" : "No saved session yet")
    }
}

private struct AgentBoardSessionRow: View {
    let session: FirstMateSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "sailboat").imageScale(.small).foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
                Text(AgentBoardProse.decodeEntities(session.title))
                    .herdrFont(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Generation \(session.generation)")
                    .herdrFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open First Mate session \(session.title)")
    }
}
