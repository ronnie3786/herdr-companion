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

    @Test("First Mate shared prose is readable in light and dark appearances at narrow large text")
    func firstMateProseAppearances() async throws {
        let assistant = FirstMateMessage(
            id: "assistant",
            featureID: "synthetic-feature",
            role: "assistant",
            text: "## Review\nThe **shared renderer** keeps selectable prose readable.\n\n- One long item wraps at narrow widths without becoming a dark island.\n- Inline `code` retains contrast.",
            status: "delivered",
            createdAt: "2030-01-01T12:00:00Z"
        )
        let human = FirstMateMessage(
            id: "human",
            featureID: "synthetic-feature",
            role: "user",
            text: "Keep the complete feature context while making this paragraph selectable.",
            status: "delivered",
            createdAt: "2030-01-01T12:00:00Z"
        )
        for scheme in [ColorScheme.light, .dark] {
            let render = try await HerdrRenderHarness.render(
                "first-mate-prose-\(scheme == .light ? "light" : "dark").png",
                size: CGSize(width: 330, height: 620)
            ) {
                VStack(spacing: 18) {
                    FirstMateMessageView(message: human)
                    FirstMateMessageView(message: assistant, canQuote: true)
                }
                .padding(12)
                .environment(\.colorScheme, scheme)
                .environment(\.herdrFontScale, .xxLarge)
                .background(FirstMatePalette(scheme: scheme).background)
            }
            render.expectSubstantial()
        }
    }

    @Test("First Mate native selection receives the light prose color")
    func firstMateNativeSelectionColor() throws {
        let firstMate = FirstMatePalette(scheme: .light)
        let prose = ChatProsePalette(
            text: firstMate.text,
            secondaryText: firstMate.secondaryText,
            accent: firstMate.accent,
            separator: firstMate.line
        )
        let root = ChatSelectableText(text: AttributedString("Readable synthetic prose"), font: .body)
            .environment(\.chatProsePalette, prose)
            .frame(width: 300)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        func find(_ view: NSView) -> ChatSelectionTextView? {
            if let text = view as? ChatSelectionTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let textView = try #require(find(host))
        let color = try #require(textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let actual = try #require(color.usingColorSpace(.sRGB))
        let expected = try #require(NSColor(firstMate.text).usingColorSpace(.sRGB))
        let chatDefault = try #require(NSColor(HerdrTheme.text).usingColorSpace(.sRGB))
        #expect(abs(actual.redComponent - expected.redComponent) < 0.01)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.01)
        #expect(abs(actual.blueComponent - expected.blueComponent) < 0.01)
        #expect(abs(actual.redComponent - chatDefault.redComponent) > 0.1)
    }

    @Test("First Mate model controls adapt at the 330-point minimum and large text")
    func firstMateModelControlsNarrow() async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var feature = try #require(store.snapshot?.feature)
        feature.modelSettingsRevision = 1
        feature.nativeSessionID = "synthetic-session"
        let render = try await HerdrRenderHarness.render(
            "first-mate-model-controls-narrow.png",
            size: CGSize(width: 330, height: 240)
        ) {
            FirstMateComposerModelControls(
                store: store,
                feature: feature,
                context: store.operationContext,
                canControl: true,
                hasQueuedWork: false,
                modelFavorites: ModelFavoritesStore()
            )
            .environment(\.herdrFontScale, .xxLarge)
            .padding(12)
            .background(FirstMatePalette(scheme: .light).surface)
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
