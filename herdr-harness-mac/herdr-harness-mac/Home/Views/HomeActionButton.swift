import SwiftUI

struct HomeActionButton: View {
    var action: HomeAction
    var compact = false
    var onCommand: (HomeCommand) -> Void

    private var isReply: Bool { action.style == .reply || action.style == .ghost }
    private var fill: Color {
        switch action.style {
        case .primary: HomePalette.accent
        case .secondary: HomePalette.ink.opacity(0.08)
        case .reply: HomePalette.accentWash
        case .ghost: .clear
        }
    }
    private var foreground: Color {
        switch action.style {
        case .primary: HomePalette.base
        case .secondary: HomePalette.ink
        case .reply: HomePalette.color(0xC4C1FA)
        case .ghost: HomePalette.secondary
        }
    }

    var body: some View {
        Button { onCommand(action.command) } label: {
            Text(action.title)
                .herdrFont(size: compact ? 12 : 13, weight: .medium)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, 5)
                .frame(minHeight: compact ? 26 : 30)
        }
        .buttonStyle(HomeButtonStyle(fill: fill,
                                     hoverFill: action.style == .primary ? HomePalette.color(0xBDB9F7) : HomePalette.ink.opacity(0.12),
                                     border: isReply ? (action.style == .reply ? HomePalette.accentLine : HomePalette.border) : .clear,
                                     hoverBorder: isReply ? HomePalette.accentLine : .clear,
                                     radius: isReply ? 15 : 7))
    }
}
