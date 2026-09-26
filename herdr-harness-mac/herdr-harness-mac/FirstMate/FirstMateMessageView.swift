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
    var retryFeedback: @MainActor () -> Void = {}
    var resolveFeedbackConflict: @MainActor () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    private var human: Bool { message.role == "user" || message.role == "human" }
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var prosePalette: ChatProsePalette { .firstMate(palette) }

    var body: some View {
        if human { humanRow } else { assistantRow }
    }

    /// The person's words in a 10% bubble on the right (MonoCode's `.fm-u`).
    private var humanRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.text)
                .font(HerdrProse.font(.userBubble, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.userBubble, scale: fontScale))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    palette.bubbleFill,
                    in: HerdrBubbleShape(singleLineHeight: (HerdrProse.Role.userBubble.lineHeight + 16) * fontScale.rawValue)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(message.text)")
                .piCopyAffordance(
                    message.text,
                    label: "Copy message",
                    identifier: "first-mate-copy-\(message.id)",
                    alignment: .topLeading,
                    offset: CGSize(width: -28, height: 4)
                )
                .frame(maxWidth: 576 * fontScale.rawValue, alignment: .trailing)
            if message.status == "queued" {
                Text("Queued")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 10)
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        .padding(.leading, 48)
    }

    /// A bubble-less reply under a "First Mate" label, with its action row.
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sailboat.fill")
                    .herdrFont(size: 12)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text("First Mate")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                    .foregroundStyle(palette.secondaryText)
                if message.status == "queued" {
                    Text("Queued")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, 16)

            PiMarkdownMessageView(
                source: message.text,
                isStreaming: false,
                id: "first-mate-\(message.featureID)-\(message.id)",
                detectsPaneLinks: false
            )
            // Issue #73: quoting stays on the rendered reply only.
            .environment(\.saveChatQuote, canQuote ? saveQuote : nil)
            .environment(\.chatQuoteSource, quoteSource)
            .environment(\.chatProsePalette, prosePalette)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if let feedback {
                FirstMateResponseFeedbackFooter(
                    messageID: message.id,
                    presentation: feedback,
                    copyText: message.text,
                    onRateUp: { rateFeedback(.up) },
                    onEditFeedback: editFeedback,
                    onRemoveRating: removeFeedback,
                    onRetry: retryFeedback,
                    onResolveConflict: resolveFeedbackConflict
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First Mate")
        // Replies without a feedback row keep the floating copy control.
        .piCopyAffordance(
            message.text,
            label: "Copy response",
            identifier: "first-mate-copy-\(message.id)",
            inset: 0,
            offset: CGSize(width: -8, height: 0),
            showsButton: feedback == nil
        )
    }
}
