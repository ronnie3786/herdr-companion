import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate conversation presentation")
@MainActor
struct FirstMateConversationPresentationTests {
    private func conversation(label: String? = nil, labelSource: String? = nil,
                              emoji: String? = nil, emojiSource: String? = nil,
                              title: String = "Synthetic feature") -> FirstMateConversation {
        let entry = FirstMateFleetEntry(featureID: "synthetic", title: title, label: label,
                                        emoji: emoji, emojiSource: emojiSource, status: "running",
                                        labelSource: labelSource)
        return FirstMateConversationList.build(hosts: [ChatFixtures.host("alpha", entries: [entry])], readState: .init())[0]
    }

    @Test("Prefills the displayed name; blank titles cannot save; counts Unicode code points")
    func nameNormalization() {
        #expect(FirstMateConversationPresentationDraft.nameLimit == 100)
        let current = conversation(label: "Friendly name", labelSource: "user")
        var draft = FirstMateConversationPresentationDraft(conversation: current)
        #expect(draft.name == "Friendly name")
        #expect(draft.emoji == current.emoji)
        #expect(draft.changes(for: current) == nil)
        draft.name = " \n \t "
        #expect(!draft.canSave)
        #expect(draft.changes(for: current) == nil)
        draft.name = "  " + String(repeating: "é", count: 101) + "  "
        #expect(draft.normalizedName == String(repeating: "é", count: 100))
        #expect(draft.changes(for: current)?.label == String(repeating: "é", count: 100))
        draft.name = "  Renamed   "
        #expect(draft.changes(for: current)?.label == "Renamed")
        #expect(draft.changes(for: current)?.emoji == nil)
    }

    @Test("Reset name sends the empty label, even when the title exceeds the limit")
    func nameReset() {
        let current = conversation(label: "Short", labelSource: "user", title: String(repeating: "Long ", count: 8))
        var draft = FirstMateConversationPresentationDraft(conversation: current)
        draft.resetName()
        #expect(draft.name == current.title)
        #expect(draft.changes(for: current)?.label == "")
        let defaultName = conversation()
        var unchanged = FirstMateConversationPresentationDraft(conversation: defaultName)
        unchanged.resetName()
        #expect(unchanged.changes(for: defaultName) == nil)
    }

    @Test("Editing only emoji never clips an unchanged long default title into a user label")
    func emojiOnlyKeepsLongDefaultTitle() {
        let current = conversation(title: String(repeating: "Synthetic long title ", count: 3))
        var draft = FirstMateConversationPresentationDraft(conversation: current)
        draft.setEmojiText("🪁")
        let change = draft.changes(for: current)
        #expect(change?.emoji == "🪁")
        #expect(FirstMateConversationPresentationEditor.labelForSave(change?.label,
                                                                     draftName: draft.name, conversation: current) == nil)
    }

    @Test("The hosted editor's emoji picker action uses the injected Character Viewer opener")
    func emojiPickerAction() {
        var opens = 0
        let editor = FirstMateConversationPresentationEditor(conversation: conversation(), save: { _, _ in nil },
                                                             openEmojiPicker: { opens += 1 })
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 440)
        host.layoutSubtreeIfNeeded()
        editor.chooseEmoji()
        #expect(opens == 1)
    }

    @Test("Emoji input retains one emoji grapheme; explicit reset clears user provenance")
    func emojiNormalizationAndReset() {
        let current = conversation(label: "Custom", labelSource: "user", emoji: "👩🏽‍💻", emojiSource: "user")
        var draft = FirstMateConversationPresentationDraft(conversation: current)
        draft.setEmojiText("letters 🇨🇦 🚀")
        #expect(draft.emoji == "🇨🇦")
        #expect(draft.changes(for: current)?.emoji == "🇨🇦")
        #expect(draft.changes(for: current)?.label == nil)
        draft.setEmojiText("letters")
        #expect(draft.emoji.isEmpty)
        #expect(draft.changes(for: current) == nil)
        draft.resetEmoji()
        #expect(draft.emoji == FirstMateDefaultEmoji.emoji(for: current.featureID))
        #expect(draft.changes(for: current)?.emoji == "")
        let alreadyDefault = conversation(emojiSource: "default")
        var noChange = FirstMateConversationPresentationDraft(conversation: alreadyDefault)
        noChange.resetEmoji()
        #expect(noChange.changes(for: alreadyDefault) == nil)
        let pinnedDefault = conversation(emoji: FirstMateDefaultEmoji.emoji(for: "synthetic"), emojiSource: "user")
        var pinned = FirstMateConversationPresentationDraft(conversation: pinnedDefault)
        pinned.resetEmoji()
        #expect(pinned.changes(for: pinnedDefault)?.emoji == "")
    }
}
