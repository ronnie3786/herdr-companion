import SwiftUI

struct ChatQuoteChip: View {
    let quote: ChatQuote
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .foregroundStyle(HerdrTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.comment).herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.text).lineLimit(1)
                Text(quote.text).herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText).lineLimit(1)
            }.frame(maxWidth: 190, alignment: .leading)
            Button("Remove quote", systemImage: "xmark", action: remove)
                .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small))
        }
        .padding(.leading, 8).padding(.trailing, 2).padding(.vertical, 3)
        .herdrCard(radius: HerdrTheme.Radius.control, fill: HerdrTheme.insetFill)
        .chatQuotePreview(quote)
        .accessibilityIdentifier("chat-quote-chip-\(quote.id)")
    }
}
