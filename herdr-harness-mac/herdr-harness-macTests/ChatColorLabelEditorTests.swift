import AppKit
import Observation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Color label editor focus", .serialized) @MainActor
struct ChatColorLabelEditorTests {
    @Observable @MainActor
    final class State {
        var text = "Lavender"
        var search = ""
        var editing = false
        var finishes: [Bool] = []
    }

    private struct FixtureView: View {
        @Bindable var state: State
        var body: some View {
            VStack {
                WorkspaceSearchField(text: $state.search, placeholder: "Filter chats")
                if state.editing {
                    ChatColorLabelEditor(text: $state.text, identifier: "color-label-test") { cancel in
                        state.finishes.append(cancel)
                        state.editing = false
                    }
                }
            }
            .padding(12)
        }
    }

    @Test("Inserting the editor takes focus from Filter chats and selects its label for immediate typing")
    func focusesNewEditor() async throws {
        let state = State()
        let (window, hosting) = makeWindow(state)
        defer { window.close() }
        let search = try #require(fields(in: hosting).first)
        #expect(window.makeFirstResponder(search))
        state.editing = true
        let field = try await waitForFocusedLabel(in: hosting)
        let editor = try #require(field.currentEditor() as? NSTextView)
        try await Task.sleep(for: .milliseconds(60))
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 0, length: "Lavender".utf16.count))
        editor.insertText("GARDEN-42 Irrigation", replacementRange: editor.selectedRange())
        #expect(state.text == "GARDEN-42 Irrigation")
        #expect(state.search.isEmpty)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(state.finishes == [false])
        #expect(!state.editing)
    }

    @Test("Updates preserve the caret; Escape cancels and a fresh edit reacquires focus")
    func caretAndCancel() async throws {
        let state = State()
        let (window, hosting) = makeWindow(state)
        defer { window.close() }
        state.editing = true
        let field = try await waitForFocusedLabel(in: hosting)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        state.search = "Refresh the view"
        hosting.layoutSubtreeIfNeeded()
        field.requestInitialFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(state.finishes == [true])
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        state.editing = true
        let newField = try await waitForFocusedLabel(in: hosting)
        #expect(newField !== field)
        #expect(newField.currentEditor()?.selectedRange == NSRange(location: 0, length: state.text.utf16.count))
    }

    @Test("Moving focus to search commits once without stealing it back")
    func focusLossCommits() async throws {
        let state = State()
        let (window, hosting) = makeWindow(state)
        defer { window.close() }
        state.editing = true
        _ = try await waitForFocusedLabel(in: hosting)
        let search = try #require(fields(in: hosting).first { !($0 is ChatColorLabelTextField) })
        #expect(window.makeFirstResponder(search))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(state.finishes == [false])
        #expect(search.currentEditor() != nil)
    }

    @Test("An editor removed before its queued focus request cannot capture the search field")
    func removedEditorDoesNotStealFocus() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let search = NSTextField(frame: NSRect(x: 0, y: 50, width: 280, height: 24))
        content.addSubview(search)
        let field = ChatColorLabelTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        content.addSubview(field)
        field.removeFromSuperview()
        #expect(window.makeFirstResponder(search))
        try await Task.sleep(for: .milliseconds(30))
        #expect(search.currentEditor() != nil)
        #expect(field.currentEditor() == nil)
    }

    private func makeWindow(_ state: State) -> (NSWindow, NSHostingView<FixtureView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: FixtureView(state: state))
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    private func waitForFocusedLabel(in view: NSView) async throws -> ChatColorLabelTextField {
        for _ in 0..<50 {
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            if let field = fields(in: view).compactMap({ $0 as? ChatColorLabelTextField }).first,
               field.currentEditor() != nil { return field }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FocusFailure.notFocused(fields(in: view).map { "\(type(of: $0)): editor=\($0.currentEditor() != nil), window=\($0.window != nil)" })
    }

    private enum FocusFailure: Error { case notFocused([String]) }
}
