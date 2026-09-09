import SwiftUI

struct WorkspaceScopeSegment: View {
    let scope: HerdrDetailScope
    let isSelected: Bool
    let unreadCount: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(scope.label, systemImage: scope.symbol)
                .labelStyle(.iconOnly)
                .herdrFont(size: 14, relativeTo: .body)
                .foregroundStyle(isSelected ? HerdrTheme.text : HerdrTheme.muted)
                .frame(minWidth: 30, minHeight: 28)
                .background(background, in: .rect(cornerRadius: 4))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The containing strip owns keyboard focus and arrow-key selection.
        .focusable(false)
        .onHover { isHovering = $0 }
        .overlay(alignment: .topTrailing) {
            if unreadCount > 0 {
                Circle()
                    .fill(HerdrTheme.alert)
                    .frame(width: 5, height: 5)
                    .offset(x: -3, y: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(unreadCount > 0 ? "\(scope.label), \(unreadCount) unread alerts" : scope.label)
        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread alerts" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return HerdrTheme.selection }
        return isHovering ? HerdrTheme.elevated : .clear
    }
}
