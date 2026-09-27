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
                .font(.system(size: 14))
                .foregroundStyle(isSelected || isHovering ? HerdrTheme.primaryText : HerdrTheme.iconTint)
                .frame(width: HerdrTheme.ControlHeight.regular, height: HerdrTheme.ControlHeight.small)
                .background(background, in: .rect(cornerRadius: HerdrTheme.Radius.control))
                .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
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
        if isSelected { return HerdrTheme.selectedFill }
        return isHovering ? HerdrTheme.hoverFill : .clear
    }
}
