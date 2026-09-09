import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The composer's Return table. Two invariants outrank every individual row:
/// 1. ⌘Return never sends and never commits a skill — it breaks the line, which
///    is the whole reason a multi-line prompt is typeable at all.
/// 2. No modified Return ever sends. ⇧/⌥Return used to defer to the field
///    editor, but that verdict reached `onSubmit` as "not a newline" and sent
///    the prompt instead.
@Suite("Composer return key")
struct ComposerReturnKeyRouterTests {
    @Test("Plain Return sends")
    func plainReturnSends() {
        #expect(outcome([]) == .send)
    }

    @Test("Command+Return always breaks the line, never sends")
    func commandReturnInsertsANewline() {
        #expect(outcome(.command) == .insertNewline)
        #expect(outcome([.command, .shift]) == .insertNewline)
        #expect(outcome([.command, .option]) == .insertNewline)
    }

    @Test("Command+Return outranks a visible skills HUD")
    func commandReturnBeatsThePalette() {
        #expect(outcome(.command, paletteVisible: true) == .insertNewline)
    }

    @Test("Shift and Option Return break the line, never send")
    func modifiedReturnsInsertANewline() {
        #expect(outcome(.shift) == .insertNewline)
        #expect(outcome(.option) == .insertNewline)
        #expect(outcome(.shift, paletteVisible: true) == .insertNewline)
        #expect(outcome(.option, paletteVisible: true) == .insertNewline)
    }

    /// The regression this table exists to prevent: a modified Return that
    /// reaches `onSubmit` before `onKeyPress` must still break the line.
    @Test("No modified Return sends, through either entry point")
    func noModifiedReturnEverSends() {
        for modifiers: EventModifiers in [.command, .shift, .option, [.command, .shift], [.shift, .option]] {
            #expect(outcome(modifiers) != .send)
            #expect(outcome(modifiers, paletteVisible: true) != .send)
        }
        for flags: NSEvent.ModifierFlags in [.command, .shift, .option, [.shift, .option]] {
            #expect(ComposerReturnKeyRouter.submitOutcome(
                isSkillsPaletteVisible: false, flags: flags) == .insertNewline)
            #expect(ComposerReturnKeyRouter.submitOutcome(
                isSkillsPaletteVisible: true, flags: flags) == .insertNewline)
        }
    }

    @Test("Return commits the highlighted skill while the HUD is up")
    func plainReturnAcceptsASkill() {
        #expect(outcome([], paletteVisible: true) == .acceptSkill)
    }

    @Test("The onSubmit backstop reads the same table from the live modifiers")
    func submitBackstopMirrorsTheKeyTable() {
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: false, flags: .command) == .insertNewline)
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: false, flags: []) == .send)
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: true, flags: .command) == .insertNewline)
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: false, flags: .shift) == .insertNewline)
    }

    @MainActor
    @Test("Newline at the caret survives synchronous draft-binding updates")
    func newlineBindingWriteback() {
        var draft = "first second"
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let editor = NSTextView()
        editor.string = draft
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let delegate = DraftDelegate { draft = $0 }
        editor.delegate = delegate

        #expect(ComposerNewlineInserter.insertNewline(in: binding, editor: editor))
        #expect(editor.string == "first\nsecond")
        #expect(draft == editor.string)
        #expect(editor.selectedRange().location == 6)
    }

    @MainActor
    @Test("Newline is retained when no editor has focus")
    func newlineFallback() {
        var draft = "first"
        let binding = Binding(get: { draft }, set: { draft = $0 })
        #expect(!ComposerNewlineInserter.insertNewline(in: binding, editor: nil))
        #expect(draft == "first\n")
    }

    @MainActor
    private final class DraftDelegate: NSObject, NSTextViewDelegate {
        let changed: (String) -> Void
        init(changed: @escaping (String) -> Void) { self.changed = changed }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { changed(editor.string) }
        }
    }

    private func outcome(
        _ modifiers: EventModifiers,
        paletteVisible: Bool = false
    ) -> ComposerReturnKeyRouter.Outcome {
        ComposerReturnKeyRouter.outcome(
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            isSkillsPaletteVisible: paletteVisible
        )
    }
}
