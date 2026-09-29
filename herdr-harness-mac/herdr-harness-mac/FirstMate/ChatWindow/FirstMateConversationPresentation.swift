import Foundation

/// A presentation-only edit: never changes the underlying feature title.
struct FirstMateConversationPresentationDraft {
    var name: String
    var emoji: String
    static let nameLimit = FirstMateHudEditing.labelLimit

    /// Explicit reset is distinct from typing the default emoji: a user can
    /// have deliberately selected the same emoji as the current default.
    private var resetNameRequested = false
    private var resetEmojiRequested = false
    private let title: String
    private let featureID: String

    init(conversation: FirstMateConversation) {
        name = conversation.name
        emoji = conversation.emoji
        title = conversation.title
        featureID = conversation.featureID
    }

    var normalizedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(Self.nameLimit)))
    }

    var canSave: Bool { !normalizedName.isEmpty }

    mutating func setEmojiText(_ text: String) {
        emoji = FirstMateHudEditing.firstEmoji(in: text) ?? ""
        resetEmojiRequested = false
    }

    mutating func resetName() {
        name = title
        resetNameRequested = true
    }

    mutating func resetEmoji() {
        emoji = FirstMateDefaultEmoji.emoji(for: featureID)
        resetEmojiRequested = true
    }

    /// An empty value resets that field on the companion; nil leaves it alone.
    func changes(for conversation: FirstMateConversation) -> (label: String?, emoji: String?)? {
        guard canSave else { return nil }
        let label: String?
        if conversation.isUserNamed && ((resetNameRequested && name == conversation.title)
                                        || name.trimmingCharacters(in: .whitespacesAndNewlines) == conversation.title) {
            label = ""
        } else if normalizedName != conversation.name {
            label = normalizedName
        } else {
            label = nil
        }
        let selectedEmoji = FirstMateHudEditing.firstEmoji(in: emoji)
        let emojiChange: String?
        if resetEmojiRequested && conversation.isUserEmoji && emoji == FirstMateDefaultEmoji.emoji(for: conversation.featureID) {
            emojiChange = ""
        } else if let selectedEmoji, selectedEmoji != conversation.emoji {
            emojiChange = selectedEmoji
        } else {
            emojiChange = nil
        }
        guard label != nil || emojiChange != nil else { return nil }
        return (label, emojiChange)
    }
}
