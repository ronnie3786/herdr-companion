import SwiftUI

struct WatchersNavigationButton: View {
    var unreadCount = 0
    var selected = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                SidebarNavRowLabel(title: "Watchers", systemImage: "eye")
                if unreadCount > 0 { Text(unreadCount > 99 ? "99+" : "\(unreadCount)").herdrFont(size: 10, weight: .bold).foregroundStyle(HerdrTheme.onBadge).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18).background(HerdrTheme.badgeFill, in: .capsule).padding(.trailing, 8).accessibilityHidden(true) }
            }.herdrRowBackground(selected: selected, hovered: hovering)
        }.buttonStyle(.herdrPlain).onHover { hovering = $0 }.accessibilityLabel("Watchers").accessibilityValue("\(unreadCount) unread inbox items").accessibilityIdentifier("open-watchers").help("Watchers (Command-9)")
    }
}
