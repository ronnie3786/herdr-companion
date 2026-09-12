import SwiftUI

struct SidebarChatRow: View {
    let pane: HerdrPane
    let recentContext: SidebarRecentContext?
    let tabColor: ChatTabColor?
    let colorLabel: String?
    let isSelected: Bool
    let isStarred: Bool
    let isUnread: Bool
    let since: Date?
    let action: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 7) {
                if differentiateWithoutColor, let tabColor {
                    Image(systemName: tabColor.symbol)
                        .font(.caption)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityHidden(true)
                }

                if let recentContext {
                    SidebarRecentChatContent(
                        pane: pane,
                        context: recentContext,
                        isStarred: isStarred,
                        isUnread: isUnread
                    )
                } else {
                    SidebarCompactChatContent(
                        pane: pane,
                        isStarred: isStarred,
                        isUnread: isUnread,
                        statusSince: since
                    )
                }
            }
            .padding(.leading, recentContext == nil ? SidebarMetrics.chatRowLeadingPadding : SidebarMetrics.rowHorizontalPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .padding(.vertical, recentContext == nil ? 5 : 10)
            .frame(minHeight: recentContext == nil ? SidebarMetrics.chatRowHeight : SidebarMetrics.recentRowHeight)
            .contentShape(.rect)
            .background(rowBackground, in: .rect(cornerRadius: SidebarMetrics.cornerRadius))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius)
                        .strokeBorder(selectionStroke, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-pane-\(pane.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if let tabColor {
            tabColor.rowBackground(selected: isSelected)
        } else if isSelected {
            HerdrTheme.elevated
        } else {
            .clear
        }
    }

    private var selectionStroke: Color {
        tabColor?.swatch.opacity(0.8) ?? HerdrTheme.accent.opacity(0.65)
    }

    private var accessibilityLabel: String {
        var parts = [pane.displayTitle, pane.displayAgentName, pane.agentStatus.title]
        if let recentContext { parts.append(recentContext.accessibilityLabel) }
        if let tabColor {
            parts.append("color group \(colorLabel ?? tabColor.defaultLabel), \(tabColor.defaultLabel)")
        }
        if isUnread { parts.append("unread") }
        if isStarred { parts.append("starred") }
        if isSelected { parts.append("selected") }
        if let since {
            let age = HerdrTimestamp.spokenAge(since: since)
            parts.append(recentContext == nil ? age : "last active \(age)")
        }
        return parts.joined(separator: ", ")
    }
}
