import SwiftUI

struct AgentCardMetadata: View {
    let session: AgentSession
    let connectionState: ConnectionState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                status
                agentName
                Spacer(minLength: 8)
                activity
            }
            VStack(alignment: .leading, spacing: 4) {
                status
                agentName
                activity
            }
        }
        .font(.caption)
    }

    private var status: some View {
        Label(session.pane.agentStatus.compactTitle, systemImage: session.pane.agentStatus.symbol)
            .foregroundStyle(SidebarRowTone.statusColor(for: session.pane.agentStatus))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var agentName: some View {
        // The list summary already identifies standard Pi agents. Preserve
        // specific agent names without repeating a generic label on every card.
        if !["pi", "π"].contains(session.agentName.lowercased()) {
            Text(session.agentName)
                .foregroundStyle(HerdrTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var activity: some View {
        if connectionState != .live && connectionState != .demo {
            Label(connectionState.title, systemImage: connectionState.symbol)
                .foregroundStyle(connectionState.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Machine \(connectionState.title), last known agent status")
        } else if let date = session.pane.lastActivityAt ?? session.pane.firstSeenAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(HerdrTimestamp.compactAge(since: date, now: context.date))
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityLabel("Last active \(HerdrTimestamp.spokenAge(since: date, now: context.date))")
            }
        }
    }
}
