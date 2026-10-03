import SwiftUI

struct HomeRadarCard: View {
    var item: HomeRadarItem
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HomeItemMark(symbol: item.symbol, emoji: item.emoji, watcherAvatar: item.watcherAvatar,
                         tone: item.tone, size: 26, circular: true)
            VStack(alignment: .leading, spacing: 7) {
                HomeRichText(text: item.body, size: 12.5, lineSpacing: 5) { onCommand(.open($0)) }
                if !item.actions.isEmpty {
                    HomeFlowLayout(spacing: 16, lineSpacing: 4) {
                        ForEach(Array(item.actions.enumerated()), id: \.element.id) { index, action in
                            Button(action.title) { onCommand(action.command) }
                                .herdrFont(size: 12.5, weight: .semibold)
                                .foregroundStyle(index == 0 ? HomePalette.accent : HomePalette.secondary)
                                .buttonStyle(HomeButtonStyle())
                                .accessibilityIdentifier("home.radar.\(item.id).\(action.id)")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(reduceTransparency ? HomePalette.color(0x282631) : HomePalette.ink.opacity(0.02))
                .overlay(HomePalette.color(item.tone).opacity(0.06), in: .rect(cornerRadius: 16))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomePalette.color(item.tone).opacity(0.20)))
        .accessibilityElement(children: .contain)
    }
}
