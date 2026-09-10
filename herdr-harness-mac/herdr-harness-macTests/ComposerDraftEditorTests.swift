import AppKit
import Observation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Composer draft scrolling", .serialized)
@MainActor
struct ComposerDraftEditorTests {
    @Test("Long drafts have a bounded native scroll view that accepts wheel events")
    func longDraftScrollsWithMouse() async throws {
        let draft = (1...40).map { "Sample prompt line \($0)" }.joined(separator: "\n")
        var handledReturn = false
        let hosting = NSHostingView(rootView:
            ComposerDraftEditor(placeholder: "Message Pi", text: .constant(draft))
                .herdrFont(size: 14)
                .onKeyPress(.return) {
                    handledReturn = true
                    return .handled
                }
                .frame(width: 320)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
        let editor = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.bounds.height > 30)
        #expect(scroll.bounds.height < 150)
        #expect(editor.bounds.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: -5, wheel2: 0, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        scroll.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.contentView.bounds.origin.y > 0)
        #expect(editor.string == draft)
        window.makeFirstResponder(editor)
        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        window.sendEvent(returnEvent)
        #expect(handledReturn, "Return must reach the composer's send/newline router")
        #expect(editor.string == draft)
    }

    @Test("Modified Return inserts at the selection in HUD and chat editors", arguments: [NSEvent.ModifierFlags.shift, .command, .option, [.command, .shift]], [4, 5])
    func modifiedReturnInRealEditor(flags: NSEvent.ModifierFlags, maximumVisibleLines: Int) async throws {
        let state = EditorState()
        var sends = 0
        let binding = Binding(get: { state.draft }, set: { state.draft = $0 })
        let hosting = NSHostingView(rootView:
            ComposerDraftEditor(placeholder: "Message Pi", text: binding, maximumVisibleLines: maximumVisibleLines)
                .onKeyPress(.return, phases: .down) { press in
                    if ComposerReturnKeyRouter.outcome(for: press, isSkillsPaletteVisible: false) == .insertNewline {
                        ComposerNewlineInserter.insertNewline(in: binding)
                    } else { sends += 1 }
                    return .handled
                }
                .frame(width: 320)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(descendants(hosting).compactMap { $0 as? NSTextView }.first)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.draft == "hello\nworld")
        #expect(editor.string == "hello\nworld")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        #expect(sends == 0)
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.string == "hello world")
        #expect(state.draft == "hello world")
        #expect(editor.tryToPerform(Selector(("redo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.string == "hello\nworld")
        #expect(state.draft == "hello\nworld")
    }

    @Test("Modified Return routing leaves other fields, plain Return, and marked text alone")
    func modifiedReturnScope() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.contentView = root
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let composer = NSTextView(frame: marker.frame)
        let otherField = NSTextView(frame: NSRect(x: 0, y: 130, width: 400, height: 100))
        root.addSubview(composer)
        root.addSubview(otherField)
        root.addSubview(marker)
        let coordinator = ComposerModifiedReturnHandler.Coordinator(text: .constant(""))
        coordinator.view = marker
        func event(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 36) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
        }
        let modified = try event(.command)
        #expect(window.makeFirstResponder(otherField))
        #expect(coordinator.handle(modified) === modified)
        window.makeFirstResponder(composer)
        let plain = try event([])
        #expect(coordinator.handle(plain) === plain)
        let otherKey = try event(.command, keyCode: 0)
        #expect(coordinator.handle(otherKey) === otherKey)
        composer.setMarkedText("sample", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(coordinator.handle(modified) === modified)
        composer.unmarkText()
        let keypadReturn = try event(.shift, keyCode: 76)
        #expect(coordinator.handle(keypadReturn) == nil)
        #expect(composer.string == "sample\n")
    }

    @Test("Command-Shift-V routes Paste code only from the focused prompt editor")
    func pasteCodeShortcutScope() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let composer = NSTextView(frame: marker.frame)
        let note = NSTextView(frame: NSRect(x: 0, y: 130, width: 400, height: 100))
        root.addSubview(composer); root.addSubview(note); root.addSubview(marker)
        var pasteCount = 0
        let coordinator = ComposerModifiedReturnHandler.Coordinator(text: .constant(""), pasteCode: { pasteCount += 1 })
        coordinator.view = marker
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "V", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
        }
        let shortcut = try event([.command, .shift])
        window.makeFirstResponder(note)
        #expect(coordinator.handle(shortcut) === shortcut)
        window.makeFirstResponder(composer)
        let normalPaste = try event(.command)
        #expect(coordinator.handle(normalPaste) === normalPaste)
        #expect(coordinator.handle(shortcut) == nil)
        #expect(pasteCount == 1)
        composer.setMarkedText("sample", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(coordinator.handle(shortcut) === shortcut)
        #expect(pasteCount == 1)
    }

    @MainActor @Observable
    final class EditorState {
        var draft = "hello world"
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
