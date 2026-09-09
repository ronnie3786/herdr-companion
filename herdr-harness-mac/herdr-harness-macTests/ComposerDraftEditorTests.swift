import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Composer draft scrolling")
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

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
