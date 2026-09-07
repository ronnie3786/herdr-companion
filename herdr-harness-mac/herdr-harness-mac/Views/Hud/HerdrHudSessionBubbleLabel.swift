import SwiftUI

/// Chat identity, current activity, and lifecycle status share one bubble.
struct HerdrHudSessionBubbleLabel: View {
    @Environment(\.herdrFontScale) private var fontScale
    let chip: HerdrHudSessionChips.Chip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.title)
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                Text(chip.emoji)
                    .herdrFont(.caption2)
                    .accessibilityHidden(true)
                Text(chip.activity)
                    .herdrFont(.caption2)
                    .italic()
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Label(chip.statusLabel, systemImage: chip.statusSymbol)
                .herdrFont(.caption2)
                .foregroundStyle(chip.status.color)
                .lineLimit(1)
                // Keep the status readable beside the existing audio controls.
                .padding(.trailing, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(
            width: HerdrHudPlacement.chipWidth,
            height: HerdrHudPlacement.chipHeight(fontScale: fontScale.rawValue)
        )
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(chip.status.color.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: chip.status == .working ? chip.status.color.opacity(0.16) : .clear, radius: 4)
        .contentShape(.rect(cornerRadius: 10))
    }
}
