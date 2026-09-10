import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("Code block paste")
struct ComposerCodeBlockPasteTests {
    @Test("Keeps literal fences and clipboard whitespace")
    func preservesText() {
        #expect(ComposerCodeBlockPaste.fenced("  let value = 1\n") == "```\n  let value = 1\n```")
        #expect(ComposerCodeBlockPaste.fenced("hello") == "```\nhello\n```")
        #expect(ComposerCodeBlockPaste.fenced("```swift\nx\n```") == "````\n```swift\nx\n```\n````")
    }

    @Test("Inserts at selection with line boundaries and UTF-16 indices")
    func insertsAtCaret() {
        #expect(ComposerCodeBlockPaste.inserting("code", into: "before after", selection: NSRange(location: 7, length: 0)) == "before \n```\ncode\n```\nafter")
        #expect(ComposerCodeBlockPaste.inserting("x", into: "👋 old", selection: NSRange(location: 3, length: 3)) == "👋 \n```\nx\n```")
        #expect(ComposerCodeBlockPaste.inserting("x", into: "hello", selection: NSRange(location: 50, length: 0)) == "hello")
    }

    @MainActor
    @Test("Reads only clipboard text and reports an empty clipboard")
    func clipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var draft = "Review this:"
        #expect(!ComposerCodeBlockPaste.paste(into: &draft, pasteboard: board))
        board.setString("let safe = true", forType: .string)
        #expect(ComposerCodeBlockPaste.paste(into: &draft, pasteboard: board))
        #expect(draft == "Review this:\n```\nlet safe = true\n```")
    }

    @MainActor
    @Test("Paste code appends after the draft, never replacing the originating selection")
    func retainedSelection() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("code", forType: .string)
        let editor = NSTextView()
        editor.string = "before old after"
        editor.setSelectedRange(NSRange(location: 7, length: 3))
        var draft = editor.string
        let selection = try #require(ComposerCodeBlockPaste.EditorSelection(editor: editor, draft: draft))
        // Closing a field editor or opening a popover can move its selection.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(ComposerCodeBlockPaste.paste(into: &draft, pasteboard: board, selection: selection))
        #expect(draft == "before old after\n```\ncode\n```")
        #expect(editor.string == draft)
    }

    @MainActor
    @Test("Retained paste destination cannot overwrite a changed draft")
    func staleSelection() throws {
        let editor = NSTextView()
        editor.string = "original"
        let selection = try #require(ComposerCodeBlockPaste.EditorSelection(editor: editor, draft: editor.string))
        #expect(selection.destination(for: "new draft") == nil)
        editor.string = "another field"
        #expect(selection.destination(for: "original") == nil)
    }
}
