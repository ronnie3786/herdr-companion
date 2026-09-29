import SwiftUI

/// Status colors and words for the chat window. The inspector keeps its
/// native mapping (`FirstMateStatusColors`), where awaiting direction is green.
enum FirstMateChatStatusStyle {
    /// Ready to plan's grey, used for dots and tints only (never as text).
    static let idleTint = Color(.sRGB, red: 0x8E / 255, green: 0x8E / 255, blue: 0x96 / 255, opacity: 1)

    /// The status word's text color. Quiet statuses read in tertiary ink.
    static func color(for status: FirstMateHudStatus) -> Color {
        switch status {
        case .blocked: HerdrTheme.alert
        case .turn: HerdrTheme.attentionBadge
        case .ready: HerdrTheme.signal
        case .working: HerdrTheme.working
        case .idle, .done, .unknown: HerdrTheme.tertiaryText
        }
    }

    /// Dots, capsule tints, and status edges keep the raw color even for the
    /// quiet statuses: complete is green and ready to plan is grey.
    static func dotColor(for status: FirstMateHudStatus) -> Color {
        switch status {
        case .blocked: HerdrTheme.alert
        case .turn: HerdrTheme.attentionBadge
        case .ready, .done: HerdrTheme.signal
        case .working: HerdrTheme.working
        case .idle, .unknown: idleTint
        }
    }

    static func tintColor(for status: FirstMateHudStatus) -> Color { dotColor(for: status) }

    static func label(for status: FirstMateHudStatus) -> String {
        switch status {
        case .blocked: "Blocked"
        case .turn: "Your turn"
        case .ready: "Ready for review"
        case .working: "Working"
        case .idle: "Ready to plan"
        case .done: "Complete"
        case .unknown: "Status unknown"
        }
    }

    /// The row's word: a working feature shows its step ("In review"), or
    /// "Working" when the step is unknown.
    static func word(for conversation: FirstMateConversation) -> String {
        if conversation.hudStatus == .working, let step = conversation.stepIndex {
            return FirstMateChatSteps.doing[step]
        }
        return label(for: conversation.hudStatus)
    }

    /// Quiet words use tertiary ink at weight 500.
    static func isQuiet(_ status: FirstMateHudStatus) -> Bool {
        [.idle, .done, .unknown].contains(status)
    }

    /// "Step 4 of 6, QA", "All six steps done", or nil when the step is unknown.
    static func stepText(for conversation: FirstMateConversation) -> String? {
        if conversation.hudStatus == .done { return "All six steps done" }
        guard let step = conversation.stepIndex else { return nil }
        return "Step \(step + 1) of \(FirstMateChatSteps.names.count), \(FirstMateChatSteps.names[step])"
    }
}
