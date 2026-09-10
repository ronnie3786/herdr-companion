import SwiftUI

struct ChatQuoteChip: View {
    let quote: ChatQuote
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble").foregroundStyle(HerdrTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.comment).herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.text).lineLimit(1)
                Text(quote.text).herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted).lineLimit(1)
            }.frame(maxWidth: 190, alignment: .leading)
            Button("Remove quote", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .frame(width: 28, height: 30)
                .foregroundStyle(HerdrTheme.mist)
        }
        .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 5)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .chatQuotePreview(quote)
        .accessibilityIdentifier("chat-quote-chip-\(quote.id)")
    }
}
