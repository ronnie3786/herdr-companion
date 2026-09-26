import SwiftUI

/// Saved Pi messages are a read-only conversation, not a First Mate composer.
/// The server supplies text-only role entries; tool calls and other Pi metadata
/// are not available here, so never imply that this is the live pane timeline.
struct FirstMateSessionTranscriptView: View {
    let messages: [FirstMateSessionMessage]?
    let fallbackText: String
    let sessionID: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    private var palette: FirstMatePalette { .init(scheme: scheme) }
    private var prosePalette: ChatProsePalette { .firstMate(palette) }
    private var bubblePalette: ChatProsePalette {
        var bubble = prosePalette
        bubble.text = palette.text
        return bubble
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrProse.turnSpacing) {
            if let messages {
                if messages.isEmpty {
                    ContentUnavailableView("No saved messages yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("This session has no recorded conversation."))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        row(message, index: index)
                    }
                }
            } else {
                // Older companions may supply only a plain-text preview.
                Text(fallbackText).herdrFont(size: HerdrTheme.TextSize.body).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.chatProsePalette, prosePalette)
        .frame(maxWidth: HerdrTheme.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("first-mate-session-transcript")
    }

    @ViewBuilder
    private func row(_ message: FirstMateSessionMessage, index: Int) -> some View {
        switch message.role {
        case "user", "human":
            PiMarkdownText(message.text, font: HerdrProse.font(.userBubble, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.userBubble, scale: fontScale))
                .environment(\.chatProsePalette, bubblePalette)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    palette.bubbleFill,
                    in: HerdrBubbleShape(singleLineHeight: (HerdrProse.Role.userBubble.lineHeight + 16) * fontScale.rawValue)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(message.text)")
                .piCopyAffordance(message.text, label: "Copy prompt", identifier: "first-mate-session-copy-\(index)",
                                  alignment: .topLeading, offset: CGSize(width: -28, height: 4))
                .frame(maxWidth: 576 * fontScale.rawValue, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case "assistant":
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .herdrFont(size: 12)
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    Text("Agent")
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                        .foregroundStyle(palette.secondaryText)
                }
                PiMarkdownMessageView(source: message.text, isStreaming: false,
                                      id: "first-mate-session-\(sessionID)-\(index)", detectsPaneLinks: false)
                    .piCopyAffordance(message.text, label: "Copy response", identifier: "first-mate-session-copy-\(index)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "toolResult":
            FirstMateToolResultCard(text: message.text, palette: palette)
        default:
            Text(message.text).herdrFont(size: HerdrTheme.TextSize.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A saved tool result, folded (MonoCode's code-block recipe). A plain chevron
/// card: DisclosureGroup is too costly inside transcript rows.
private struct FirstMateToolResultCard: View {
    let text: String
    let palette: FirstMatePalette
    @State private var isExpanded = false

    var body: some View {
        PiDisclosureCard(isExpanded: $isExpanded, chevronColor: palette.iconTint) {
            Text(text.isEmpty ? "No text output" : text)
                .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.bottom, 10)
        } label: {
            Label("Tool result", systemImage: "wrench.and.screwdriver")
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 12)
        .background(palette.text.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line) }
    }
}
