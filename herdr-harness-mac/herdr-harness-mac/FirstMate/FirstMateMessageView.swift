import SwiftUI

struct FirstMateMessageView: View {
    let message: FirstMateMessage
    var isPendingDecision = false
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
                .accessibilityLabel("You: \(message.text)\(message.status == "sending" ? ", Sending" : message.status == "failed" ? ", Not sent" : message.status == "unconfirmed" ? ", Delivery unconfirmed" : "")")
                .piCopyAffordance(
                    message.text,
                    label: "Copy message",
                    identifier: "first-mate-copy-\(message.id)",
                    alignment: .topLeading,
                    offset: CGSize(width: -28, height: 4)
                )
                .frame(maxWidth: 576 * fontScale.rawValue, alignment: .trailing)
            if ["queued", "sending", "failed", "unconfirmed"].contains(message.status) {
                Text(message.status == "sending" ? "Sending…" : message.status == "queued" ? "Queued" : message.status == "failed" ? "Not sent" : "Delivery unconfirmed")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(["failed", "unconfirmed"].contains(message.status) ? HerdrTheme.alert : palette.tertiaryText)
                    .accessibilityIdentifier("first-mate-send-status-\(message.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 10)
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        .padding(.leading, 48)
    }

    /// A completed reply keeps thumbs up, thumbs down, and Copy inside its
    /// response bubble. The feedback presentation still owns every capability,
    /// load, write, and saved-state gate.
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sailboat.fill")
                    .herdrFont(size: 12)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text("First Mate")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                    .foregroundStyle(palette.secondaryText)
                if isPendingDecision {
                    Label("Decision needed", systemImage: "hand.raised")
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(HerdrTheme.warning)
                        .accessibilityIdentifier("first-mate-pending-decision-\(message.id)")
                }
                if message.status == "queued" {
                    Text("Queued")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                }
                SkimPendingLabel(skim: message.skim)
                    .environment(\.chatProsePalette, prosePalette)
            }

            VStack(alignment: .leading, spacing: 0) {
                // A long reply shows its skim when one is ready; the full reply
                // stays what Copy, quotes, and feedback act on.
                SkimmableReply(messageID: message.id, reply: message.text, skim: message.skim) {
                    PiMarkdownMessageView(
                        source: message.text,
                        isStreaming: false,
                        id: "first-mate-\(message.featureID)-\(message.id)",
                        detectsPaneLinks: false
                    )
                }
                // Issue #73: quoting stays on the rendered reply only.
                .environment(\.saveChatQuote, canQuote ? saveQuote : nil)
                .environment(\.chatQuoteSource, quoteSource)
                .environment(\.chatProsePalette, prosePalette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, 13)
                .padding(.bottom, 4)

                if FirstMateFeedbackEligibility.isEligible(message) {
                    responseActions
                        .padding(.horizontal, 9)
                        .padding(.bottom, 4)
                }
            }
            .background(HerdrTheme.inkFill(0.06), in: .rect(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
            // Keep the existing right-click route without drawing a second,
            // floating copy button outside the response bubble.
            .piCopyAffordance(
                message.text,
                label: "Copy response",
                identifier: "first-mate-copy-context-\(message.id)",
                showsButton: false
            )
        }
        .padding(.top, 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First Mate")
    }

    @ViewBuilder private var responseActions: some View {
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
        } else {
            PiCopyButton(
                text: message.text,
                label: "Copy response",
                accessibilityIdentifier: "first-mate-copy-\(message.id)"
            )
        }
    }
}
