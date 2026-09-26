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
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .padding(.bottom, 6)
                if content.agents.isEmpty {
                    Text("No agents assigned yet. First Mate adds them as the plan takes shape.")
                        .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                }
                ForEach(content.agents) { agent in
                    AgentBoardAgentRow(agent: agent, open: { openAgent(agent) })
                }
                if !content.coordinatorSessions.isEmpty {
                    // A plain chevron button: DisclosureGroup is off limits in
                    // scrolling lists (plan §4).
                    Button {
                        showsSessions.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                                .foregroundStyle(HerdrTheme.iconTint)
                                .rotationEffect(.degrees(showsSessions ? 90 : 0))
                                .accessibilityHidden(true)
                            Text("First Mate sessions (\(content.coordinatorSessions.count))")
                                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                                .foregroundStyle(HerdrTheme.secondaryText)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsSessions ? "Expanded" : "Collapsed")
                    .padding(.top, 12)
                    if showsSessions {
                        ForEach(content.coordinatorSessions) { session in
                            AgentBoardSessionRow(session: session) { openSession(session) }
                        }
                        .padding(.leading, 16)
                    }
                }
                if content.sessionsTruncated {
                    Text("Earlier sessions are in the full First Mate view.")
                        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
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
        case .waiting, .other: ("circle", HerdrTheme.tertiaryText)
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
                    .herdrIconSlot(width: 16)
                    .accessibilityHidden(true)
                Text(agent.title)
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(agent.statusTitle)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .fixedSize()
                Image(systemName: "arrow.up.right")
                    .imageScale(.small)
                    .foregroundStyle(HerdrTheme.accent)
                    .opacity(isHovered && agent.canOpen ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 30)
            .background(isHovered && agent.canOpen ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .herdrHairline(.bottom, color: HerdrTheme.rowDivider)
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
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Generation \(session.generation)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open First Mate session \(session.title)")
    }
}
