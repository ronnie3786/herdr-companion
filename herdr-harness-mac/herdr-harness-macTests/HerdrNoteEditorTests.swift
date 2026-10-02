import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Note editor", .serialized)
@MainActor
struct HerdrNoteEditorTests {
    @Test("Completed inline Markdown formats at the cursor", arguments: ["**bold**", "*italic*", "_italic_", "~~done~~", "**👩🏽‍💻 café**"])
    func typingMarkdown(token: String) throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        for character in "Before \(token) after" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let expected = token.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "~", with: "")
        #expect(editor.string == "Before \(expected) after")
        let format: HerdrNoteTextStyle.Format = token.hasPrefix("**") ? .bold : token.hasPrefix("~~") ? .strikethrough : .italic
        #expect(HerdrNoteTextStyle.contains(format, in: editor.attributedString().attributes(at: 7, effectiveRange: nil)))
        #expect(!HerdrNoteTextStyle.contains(format, in: editor.attributedString().attributes(at: editor.string.utf16.count - 1, effectiveRange: nil)))
        #expect(editor.selectedRange().location == editor.string.utf16.count)
    }

    @Test("Incomplete, escaped, code and identifier text stays literal", arguments: ["**unfinished*", "some_name_here", "\\**literal**", "`**code**`", "```\n**code**", "** spaced **"])
    func literalText(text: String) {
        let (window, editor) = makeEditor()
        defer { window.close() }
        for character in text { editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(editor.string == text)
    }

    @Test("Conversion in the middle preserves following text and can undo and redo")
    func middleAndUndo() async throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        // A loaded note has no typing undo group from test fixture setup.
        editor.textStorage?.setAttributedString(NSAttributedString(string: "Before **hello* after", attributes: HerdrNoteTextStyle.attributes([:], ink: .black)))
        editor.setSelectedRange(NSRange(location: 15, length: 0))
        editor.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "Before hello after")
        #expect(editor.selectedRange() == NSRange(location: 12, length: 0))
        let undo = try #require(editor.undoManager)
        undo.undo()
        #expect(editor.string == "Before **hello* after")
        undo.redo()
        #expect(editor.string == "Before hello after")
        #expect(HerdrNoteTextStyle.contains(.bold, in: editor.attributedString().attributes(at: 7, effectiveRange: nil)))
    }

    @Test("Basic formatting combines, toggles, persists, and normalizes old fonts")
    func formattingAndPersistence() throws {
        var old = AttributedString("Styled link")
        old.font = .custom("Times New Roman", size: 32).bold().italic()
        old.foregroundColor = .red
        old.backgroundColor = .yellow
        old.underlineStyle = .single
        old.link = URL(string: "https://example.invalid/note")
        let native = HerdrNoteTextStyle.native(old, ink: .black)
        let font = try #require(native.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == HerdrNoteTextStyle.fontSize)
        #expect(font.familyName == HerdrNoteTextStyle.font().familyName)
        #expect(HerdrNoteTextStyle.contains(.bold, in: native.attributes(at: 0, effectiveRange: nil)))
        #expect(HerdrNoteTextStyle.contains(.italic, in: native.attributes(at: 0, effectiveRange: nil)))
        #expect(native.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        let (window, editor) = makeEditor()
        defer { window.close() }
        editor.insertText(native, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: native.length))
        editor.toggle(.underline)
        editor.toggle(.strikethrough)
        #expect(!editor.isActive(.underline))
        #expect(editor.isActive(.bold))
        #expect(editor.isActive(.italic))
        #expect(editor.isActive(.strikethrough))
        var note = HerdrNote(title: "Synthetic note")
        note.richBody = HerdrNoteTextStyle.rich(editor.attributedString())
        let decoded = try JSONDecoder().decode(HerdrNote.self, from: JSONEncoder().encode(note))
        #expect(decoded.richBody == note.richBody)
        #expect(decoded.body == "Styled link")
        #expect(decoded.richBody.runs.first?.link == old.link)
    }

    @Test("Command B, I and U operate only in the note editor")
    func keyboardFormatting() throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        for (key, format) in [("b", HerdrNoteTextStyle.Format.bold), ("i", .italic), ("u", .underline)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            #expect(editor.performKeyEquivalent(with: event))
            #expect(editor.isActive(format))
        }
        editor.insertText("Basics", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(editor.isActive(.bold))
        #expect(editor.isActive(.italic))
        #expect(editor.isActive(.underline))
    }

    @Test("Formatting a selection can be undone and Escape closes the note")
    func formatUndoAndEscape() throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        editor.textStorage?.setAttributedString(NSAttributedString(string: "A selection", attributes: HerdrNoteTextStyle.attributes([:], ink: .black)))
        editor.setSelectedRange(NSRange(location: 2, length: 9))
        editor.toggle(.underline)
        #expect(editor.isActive(.underline))
        let undo = try #require(editor.undoManager)
        undo.undo()
        editor.setSelectedRange(NSRange(location: 2, length: 9))
        #expect(!editor.isActive(.underline))
        undo.redo()
        editor.setSelectedRange(NSRange(location: 2, length: 9))
        #expect(editor.isActive(.underline))
        var didClose = false
        editor.onEscape = { didClose = true }
        editor.cancelOperation(nil)
        #expect(didClose)
    }

    @Test("Rich paste keeps basics and discards foreign fonts, sizes, and colors")
    func richPaste() throws {
        let (window, editor) = makeEditor()
        defer { window.close() }
        let pasted = NSAttributedString(string: "Pasted", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 42), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.red, .underlineStyle: NSUnderlineStyle.double.rawValue
        ])
        editor.insertText(pasted, replacementRange: NSRange(location: NSNotFound, length: 0))
        let values = editor.attributedString().attributes(at: 0, effectiveRange: nil)
        #expect((values[.font] as? NSFont)?.pointSize == HerdrNoteTextStyle.fontSize)
        #expect(values[.foregroundColor] as? NSColor == editor.ink)
        #expect(values[.backgroundColor] == nil)
        #expect(values[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(HerdrNoteTextStyle.contains(.bold, in: values))
    }

    @Test("Hosted editor renders, keeps native edits and selection, and uses dark ink")
    func hostedEditor() async throws {
        var value = AttributedString("A little more clarity\n\nOne font. Room to think.\nBold, italic, and underline, right where you need them.")
        value[value.range(of: "Bold")!].font = .body.bold()
        value[value.range(of: "italic")!].font = .body.italic()
        value[value.range(of: "underline")!].underlineStyle = .single
        let host = NSHostingView(rootView: HerdrNoteRichEditor(text: Binding(get: { value }, set: { value = $0 }), ink: .black, isEditable: true, focusRequest: UUID())
            .frame(width: 360, height: 320).padding(12).background(HerdrNoteColor.yellow.fill).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 384, height: 344), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(descendants(host).compactMap { $0 as? HerdrNoteTextView }.first)
        #expect(editor.bounds.width > 300)
        #expect(editor.visibleRect.height > 200)
        #expect(editor.insertionPointColor.usingColorSpace(.sRGB)?.redComponent == 0)
        #expect((editor.selectedTextAttributes[.backgroundColor] as? NSColor)?.alphaComponent == 0.18)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" More.", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(String(value.characters).hasSuffix(" More."))
        #expect(editor.selectedRange().location == editor.string.utf16.count)
        if let path = ProcessInfo.processInfo.environment["HERDR_NOTE_PREVIEW_PATH"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test("The complete note card keeps the editor on the same paper surface")
    func fullNoteCard() async throws {
        let suite = "NoteCardRender-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = HerdrAppModel(arguments: ["Tests", "-HerdrDemoMode"], userDefaults: defaults)
        let controller = HerdrHudController(userDefaults: defaults)
        let notes = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults), promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: directory.appendingPathComponent("notes.json"), saveDelay: .seconds(60))
        await notes.waitForPersistenceRestoreForTesting()
        let id = notes.createNote()
        notes.updateTitle("Room to think", for: id)
        var body = AttributedString("A little more clarity\n\nOne font. Room to think.\n\nBold, italic, and underline, right where you need them.")
        body[body.range(of: "Bold")!].font = .body.bold()
        body[body.range(of: "italic")!].font = .body.italic()
        body[body.range(of: "underline")!].underlineStyle = .single
        notes.updateBody(body, for: id)
        let host = NSHostingView(rootView: HerdrNoteCardView(model: model, controller: controller, notes: notes, noteID: id))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: controller.noteCardSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(descendants(host).compactMap { $0 as? HerdrNoteTextView }.first)
        #expect(!editor.drawsBackground)
        #expect(editor.textContainerInset.width == 0)
        #expect(editor.textContainer?.lineFragmentPadding == 0)
        #expect(editor.visibleRect.height > 150)
        if let folder = ProcessInfo.processInfo.environment["HERDR_NOTE_PREVIEW_DIR"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("mac-note-card.png"))
        }
    }

    private func makeEditor() -> (NSWindow, HerdrNoteTextView) {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = HerdrNoteTextView(frame: window.contentLayoutRect)
        editor.allowsUndo = true
        editor.isRichText = true
        editor.ink = .black
        editor.typingAttributes = HerdrNoteTextStyle.attributes([:], ink: .black)
        window.contentView = editor
        window.makeFirstResponder(editor)
        return (window, editor)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
