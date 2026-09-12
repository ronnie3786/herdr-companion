import SwiftUI

struct SidebarCompactChatContent: View {
    let pane: HerdrPane
    let isStarred: Bool
    let isUnread: Bool
    let statusSince: Date?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 5) {
                identity
                SidebarStatusAgeLabel(status: pane.agentStatus, since: statusSince)
                    .font(.caption)
                    .foregroundStyle(SidebarRowTone.statusColor(for: pane.agentStatus))
            }
        } else {
            HStack(spacing: 7) {
                identity
                Spacer(minLength: 4)
                SidebarStatusAgeLabel(status: pane.agentStatus, since: statusSince)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SidebarRowTone.statusColor(for: pane.agentStatus))
                    .fixedSize()
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            SidebarStatusMark(status: pane.agentStatus)

            Text(pane.displayTitle)
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .multilineTextAlignment(.leading)

            if isUnread {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityLabel("Unread")
            }

            if isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityLabel("Starred")
            }
        }
    }
}
