import SwiftUI

struct SidebarRecentChatContent: View {
    let pane: HerdrPane
    let context: SidebarRecentContext
    let isStarred: Bool
    let isUnread: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(pane.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

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

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    location
                    status
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    location
                    Spacer(minLength: 4)
                    status
                }
            }
        }
    }

    private var location: some View {
        Text("\(context.machine) · \(Text(context.workspace).bold())")
            .font(.caption)
            .foregroundStyle(HerdrTheme.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .multilineTextAlignment(.leading)
            .accessibilityLabel(context.accessibilityLabel)
    }

    private var status: some View {
        Label(pane.agentStatus.compactTitle, systemImage: pane.agentStatus.symbol)
            .font(.caption)
            .foregroundStyle(SidebarRowTone.statusColor(for: pane.agentStatus))
            .fixedSize(horizontal: false, vertical: true)
    }
}
