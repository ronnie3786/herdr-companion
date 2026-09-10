import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Chat polish renders", .serialized)
@MainActor
struct ChatPolishRenderTests {
    private let quote = ChatQuote(text: "Keep the previous conversation readable, but start with fresh context.\nSession boundaries should feel calm and clear.", comment: "Please focus on the transition between sessions.", source: "Pi session 00000000-0000-0000-0000-000000000001")

    @Test("Quote editor and attachment preview render in the chat theme")
    func quoteSurfaces() async throws {
        let editor = try await HerdrRenderHarness.render("chat-quote-editor.png", size: CGSize(width: 450, height: 290)) {
            ChatQuoteEditor(text: quote.text, source: quote.source, save: { _ in }, dismiss: {})
        }
        editor.expectSubstantial()
        let preview = try await HerdrRenderHarness.render("chat-quote-preview.png", size: CGSize(width: 410, height: 340)) {
            ChatQuotePreview(quote: quote)
        }
        preview.expectSubstantial()
    }

    @Test("Previous session retains readable history and copyable provenance")
    func closedSession() async throws {
        let session = PiClosedSession(id: "00000000-0000-0000-0000-000000000001", turns: [
            PiConversationTurn(id: "turn", user: PiUserMessage(id: "user", text: "Can we refine the chat layout?"),
                               items: [.assistant(PiAssistantBlock(id: "reply", text: "Yes. Keep the history readable and use a quiet divider for the next session.", status: .complete))], isActive: false)
        ], wasTruncated: false)
        let render = try await HerdrRenderHarness.render("chat-closed-session.png", size: CGSize(width: 680, height: 420)) {
            PiClosedSessionView(session: session, initiallyExpanded: true)
                .environment(\.saveChatQuote, { _ in }).padding(24)
        }
        render.expectSubstantial()
    }

    @Test("Note tooltips appear after a delay without taking editor focus")
    func delayedTooltip() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        let editor = NSTextView(frame: root.bounds)
        let tooltip = HerdrDelayedTooltip.TooltipView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        tooltip.title = "Tidy with AI"
        root.addSubview(editor)
        root.addSubview(tooltip)
        window.contentView = root
        window.makeFirstResponder(editor)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 1, userData: nil))
        tooltip.mouseEntered(with: event)
        #expect(window.childWindows?.isEmpty != false)
        try await Task.sleep(for: .milliseconds(800))
        #expect(window.childWindows?.count == 1)
        #expect(window.firstResponder === editor)
        tooltip.mouseExited(with: event)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test("Native note cursor uses ink, not the dark window's white insertion point")
    func noteCursor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        let editor = NSTextView(frame: root.bounds)
        editor.insertionPointColor = .white
        let ink = HerdrNoteEditorInk.InkView(frame: root.bounds)
        ink.ink = .black
        root.addSubview(editor)
        root.addSubview(ink)
        window.contentView = root
        ink.layout()
        #expect(editor.insertionPointColor == .black)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == NSColor.black.withAlphaComponent(0.18))
    }
}
