import SwiftUI

struct FirstMateMessageView: View {
    let message: FirstMateMessage
    var canQuote = false
    var quoteSource = "First Mate"
    var saveQuote: @MainActor (ChatQuote) async throws -> Void = { _ in }
    var feedback: FirstMateResponseFeedbackPresentation?
    var rateFeedback: @MainActor (FirstMateFeedbackRating) -> Void = { _ in }
    var editFeedback: @MainActor () -> Void = {}
    var removeFeedback: @MainActor () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    private var human: Bool { message.role == "user" || message.role == "human" }
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var prosePalette: ChatProsePalette {
        .init(text: palette.text, secondaryText: palette.secondaryText, accent: palette.accent, separator: palette.line)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: human ? "person.crop.circle" : "sailboat.fill")
                .herdrFont(.title3)
                .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                .frame(width: 30, height: 30)
                .background(FirstMatePalette(scheme: scheme).accent.opacity(0.1), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(human ? "You" : "First Mate")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(palette.text)
                    if message.status == "queued" {
                        Text("Queued").herdrFont(.caption2).foregroundStyle(.secondary)
                    }
                }

                Group {
                    if human {
                        ChatSelectableText(text: AttributedString(message.text), font: HerdrProse.font(.body, scale: fontScale), lineSpacing: 5)
                            .environment(\.saveChatQuote, nil)
                    } else {
                        PiMarkdownMessageView(
                            source: message.text,
                            isStreaming: false,
                            id: "first-mate-\(message.featureID)-\(message.id)",
                            detectsPaneLinks: false
                        )
                        .environment(\.saveChatQuote, canQuote ? saveQuote : nil)
                        .environment(\.chatQuoteSource, quoteSource)
                    }
                }
                .environment(\.chatProsePalette, prosePalette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    human ? palette.accent.opacity(0.06) : palette.surface,
                    in: .rect(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(palette.line)
                }

                if !human, let feedback {
                    FirstMateResponseFeedbackFooter(
                        messageID: message.id,
                        presentation: feedback,
                        onRateUp: { rateFeedback(.up) },
                        onEditFeedback: editFeedback,
                        onRemoveRating: removeFeedback
                    )
                }
            }
        }
        .piCopyAffordance(
            message.text,
            label: human ? "Copy message" : "Copy response",
            identifier: "first-mate-copy-\(message.id)",
            inset: 0,
            offset: CGSize(width: 24, height: 0)
        )
    }
}
