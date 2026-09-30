import SwiftUI

/// Secondary saved/recovery information precedes the single final action/time
/// row. No flexible Spacer participates in intrinsic bubble measurement.
struct FirstMateMessageFooter: View {
    let messageID: String
    var feedback: FirstMateResponseFeedbackPresentation? = nil
    var copyText: String? = nil
    var timestamp: FirstMateMessageTimestamp? = nil
    var onRateUp: @MainActor () -> Void = {}
    var onEditFeedback: @MainActor () -> Void = {}
    var onRemoveRating: @MainActor () -> Void = {}
    var onRetry: @MainActor () -> Void = {}
    var onResolveConflict: @MainActor () -> Void = {}

    private func controls(_ feedback: FirstMateResponseFeedbackPresentation) -> FirstMateResponseFeedbackFooter {
        FirstMateResponseFeedbackFooter(
            messageID: messageID, presentation: feedback, copyText: copyText,
            onRateUp: onRateUp, onEditFeedback: onEditFeedback,
            onRemoveRating: onRemoveRating, onRetry: onRetry, onResolveConflict: onResolveConflict
        )
    }

    var body: some View {
        FirstMateBubbleStack(spacing: 4, fillsProposedWidth: true) {
            if let feedback, feedback.hasSavedRating || feedback.isSaving || feedback.saveErrorMessage != nil {
                controls(feedback).secondaryInformation
                    .firstMateFooterPart(messageID, "secondary")
            }
            FirstMateActionTimeLayout {
                HStack(spacing: 2) {
                    if let feedback { controls(feedback).ratingActions }
                    if let copyText {
                        PiCopyButton(text: copyText, label: "Copy response", accessibilityIdentifier: "first-mate-copy-\(messageID)")
                    }
                }
                .fixedSize()
                .firstMateFooterPart(messageID, "actions")
                if let timestamp { FirstMateTimestampLabel(timestamp: timestamp, messageID: messageID) }
            }
            .layoutValue(key: FirstMateBubbleFullWidthKey.self, value: true)
            .firstMateFooterPart(messageID, "final-row")
        }
        .layoutValue(key: FirstMateBubbleFullWidthKey.self, value: true)
        .firstMateFooterPart(messageID, "footer")
        .accessibilityIdentifier(feedback == nil ? "first-mate-footer-\(messageID)" : "first-mate-feedback-\(messageID)")
    }
}

/// Icons retain their hit targets; metadata wraps in the remaining trailing
/// allocation. Both are vertically centered, even for a multi-line date.
struct FirstMateActionTimeLayout: Layout {
    var gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let actions = subviews.first else { return .zero }
        let actionSize = actions.sizeThatFits(.unspecified)
        guard subviews.count > 1 else { return actionSize }
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (actionSize.width + gap + ideal.width)
        let time = subviews[1].sizeThatFits(.init(width: max(0, width - actionSize.width - gap), height: nil))
        return CGSize(width: width, height: max(actionSize.height, time.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let actions = subviews.first else { return }
        let size = actions.sizeThatFits(.unspecified)
        actions.place(at: CGPoint(x: bounds.minX, y: bounds.midY - size.height / 2), proposal: .init(size))
        if subviews.count > 1 {
            let width = max(0, bounds.width - size.width - gap)
            let time = subviews[1].sizeThatFits(.init(width: width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX - time.width, y: bounds.midY - time.height / 2),
                              proposal: .init(width: time.width, height: time.height))
        }
    }
}

struct FirstMateBubbleFullWidthKey: LayoutValueKey {
    static let defaultValue = false
}

/// Hosted geometry evidence for the actual production views, in bubble-local
/// coordinates. Anchors do not introduce state or per-row observers.
struct FirstMateFooterLayoutKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func firstMateFooterPart(_ messageID: String, _ part: String) -> some View {
        // A sibling background contributes its bounds without an ancestor
        // anchor writer replacing the evidence emitted by child controls.
        background {
            Color.clear.anchorPreference(key: FirstMateFooterLayoutKey.self, value: .bounds) {
                ["\(messageID):\(part)": $0]
            }
        }
    }
}
