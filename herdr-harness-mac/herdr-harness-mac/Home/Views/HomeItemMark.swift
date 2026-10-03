import SwiftUI

struct HomeItemMark: View {
    var symbol: String
    var emoji: String? = nil
    var watcherAvatar: String? = nil
    var tone: HomeTone = .accent
    var size: CGFloat = 40
    var circular = false

    var body: some View {
        Group {
            if let watcherAvatar {
                WatcherAvatar(avatar: watcherAvatar, size: size)
            } else if let emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: size * 0.5))
                    .frame(width: size, height: size)
                    .background(HomePalette.color(0x2A2244), in: .circle)
                    .background(RadialGradient(colors: [HomePalette.accent.opacity(0.2), .clear], center: .top,
                        startRadius: 0, endRadius: size * 0.68), in: .circle)
                    .overlay(Circle().strokeBorder(HomePalette.accent.opacity(0.2), lineWidth: 1))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.49, weight: .medium))
                    .foregroundStyle(HomePalette.color(tone))
                    .frame(width: size, height: size)
                    .background(HomePalette.color(tone).opacity(0.13),
                        in: .rect(cornerRadius: size * (circular ? 0.5 : 0.3)))
                    .overlay(RoundedRectangle(cornerRadius: size * (circular ? 0.5 : 0.3))
                        .strokeBorder(HomePalette.color(tone).opacity(0.26), lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}
