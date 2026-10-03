import SwiftUI

/// Native, baseline-aligned text with focusable chips and exact source whitespace.
struct HomeRichText: View {
    var text: HomeText
    var size: CGFloat = 16.5
    var lineSpacing: CGFloat = 8
    var onOpen: (HomeRoute) -> Void
    @Environment(\.herdrFontScale) private var fontScale

    private var chips: [HomeChip] {
        text.runs.compactMap { if case .chip(let chip) = $0 { chip } else { nil } }
    }

    var body: some View {
        HomeInlineLayout(lineSpacing: lineSpacing * fontScale.rawValue) {
            ForEach(Array(HomeInlineToken.tokenize(text).enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let word), .space(let word):
                    Text(verbatim: word).herdrFont(size: size)
                        .foregroundStyle(HomePalette.prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutValue(key: HomeInlineKindKey.self, value: token.isSpace ? .space : .content)
                case .lineBreak:
                    Text(" ").herdrFont(size: size).hidden()
                        .layoutValue(key: HomeInlineKindKey.self, value: .lineBreak)
                case .chip(let chip):
                    HomeChipView(chip: chip, onOpen: onOpen)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.plainText)
        .accessibilityChildren {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button(chip.title) { onOpen(chip.route) }
            }
        }
    }
}

private struct HomeChipView: View {
    let chip: HomeChip
    var onOpen: (HomeRoute) -> Void
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        Button { onOpen(chip.route) } label: {
            HStack(spacing: 5) {
                HomeItemMark(symbol: chip.symbol, emoji: chip.emoji, watcherAvatar: chip.watcherAvatar,
                             tone: chip.tone, size: 17 * fontScale.rawValue, circular: true)
                Text(chip.title).herdrFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(HomePalette.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 2).padding(.trailing, 8)
            .frame(minHeight: 21 * fontScale.rawValue)
        }
        .buttonStyle(HomeButtonStyle(fill: HomePalette.color(chip.tone).opacity(0.11),
            hoverFill: HomePalette.color(chip.tone).opacity(0.22),
            border: HomePalette.color(chip.tone).opacity(0.36), hoverBorder: HomePalette.color(chip.tone), radius: 11))
        .background(HomePalette.ink.opacity(0.06), in: .capsule)
        .help("Open \(chip.title)")
        .accessibilityLabel("Open \(chip.title)")
    }
}
