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
    private var prosePalette: ChatProsePalette {
        .init(text: palette.text, secondaryText: palette.secondaryText,
              accent: palette.accent, separator: palette.line)
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
                Text(fallbackText).herdrFont(.body).lineSpacing(6).textSelection(.enabled)
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
            PiMarkdownText(message.text, font: HerdrProse.font(.body, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.body, scale: fontScale))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                        .stroke(palette.line)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 42)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(message.text)")
                .piCopyAffordance(message.text, label: "Copy prompt", identifier: "first-mate-session-copy-\(index)")
        case "assistant":
            VStack(alignment: .leading, spacing: 8) {
                Label("Agent", systemImage: "sparkle")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(palette.accent)
                PiMarkdownMessageView(source: message.text, isStreaming: false,
                                      id: "first-mate-session-\(sessionID)-\(index)", detectsPaneLinks: false)
                    .piCopyAffordance(message.text, label: "Copy response", identifier: "first-mate-session-copy-\(index)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "toolResult":
            DisclosureGroup {
                Text(message.text.isEmpty ? "No text output" : message.text)
                    .herdrFont(.body, monospaced: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } label: {
                Label("Tool result", systemImage: "wrench.and.screwdriver")
                    .herdrFont(.caption)
            }
            .padding(12)
            .background(palette.surface, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line))
        default:
            Text(message.text).herdrFont(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
