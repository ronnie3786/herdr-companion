import SwiftUI

struct AgentSessionCard: View {
    let session: AgentSession
    let connectionState: ConnectionState
    let isUnread: Bool
    let isStarred: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text(session.pane.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(HerdrTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isUnread {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(HerdrTheme.accent)
                        .accessibilityLabel("Unread")
                }
                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .accessibilityLabel("Starred")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)
            }

            Label(session.agentName, systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(HerdrTheme.muted)
                .accessibilityLabel("Agent: \(session.agentName)")
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack {
                    status
                    Spacer(minLength: 8)
                    activity
                }
                VStack(alignment: .leading, spacing: 6) {
                    status
                    activity
                }
            }
            .font(.caption)
        }
        .multilineTextAlignment(.leading)
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        Label(session.pane.agentStatus.compactTitle, systemImage: session.pane.agentStatus.symbol)
            .foregroundStyle(SidebarRowTone.statusColor(for: session.pane.agentStatus))
            .fixedSize()
    }

    @ViewBuilder
    private var activity: some View {
        if connectionState != .live && connectionState != .demo {
            Label(connectionState.title, systemImage: connectionState.symbol)
                .foregroundStyle(connectionState.color)
                .accessibilityLabel("Machine \(connectionState.title), last known agent status")
        } else if let date = session.pane.lastActivityAt ?? session.pane.firstSeenAt {
            Text(date, style: .relative)
                .foregroundStyle(HerdrTheme.muted)
                .accessibilityLabel(Text("Last active \(date, style: .relative) ago"))
        }
    }
}
