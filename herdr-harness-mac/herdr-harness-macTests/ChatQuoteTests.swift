import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Chat quotes", .serialized)
@MainActor
struct ChatQuoteTests {
    @Test("Quoted segments are sent inline, with each comment and no file paths")
    func inlineQuotedSegments() throws {
        let first = ChatQuote(text: "Hello 👋🏽\nlet café = 1", comment: "Explain this example.", source: "Pi session synthetic-session")
        let second = ChatQuote(text: "A second detail", comment: "Change this too.", source: "Pi session synthetic-session")
        let prompt = ChatQuote.prompt("Please proceed.", quotes: [first, second])
        #expect(prompt == "Please proceed.\n\nQuoted response segments:\n\n> Hello 👋🏽\n> let café = 1\n\nUser’s message: Explain this example.\n\n> A second detail\n\nUser’s message: Change this too.")
        #expect(!prompt.contains("Attachment:"))
        #expect(!prompt.contains("synthetic-session"))
        #expect(ChatQuote.prompt("Unchanged", quotes: []) == "Unchanged")
        #expect(ChatQuote.prompt("", quotes: [first]).hasPrefix("Quoted response segments:"))
        #expect(try JSONDecoder().decode(ChatQuote.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test("HUD quote Save stages context without sending or modifying the draft")
    func hudStagesQuote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = HerdrHudSession(userDefaults: defaults, persistenceURL: root.appendingPathComponent("hud.json"))
        session.draft = "My next question"
        let quote = ChatQuote(text: "An earlier response", comment: "Check this detail", source: "HUD exchange example")
        session.addQuote(quote)
        #expect(session.draft == "My next question")
        #expect(session.exchanges.isEmpty)
        #expect(!session.isRunning)
        #expect(session.pendingQuotes == [quote])
        #expect(session.pendingAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        session.pendingQuotes.removeAll { $0.id == quote.id }
        #expect(session.pendingQuotes.isEmpty)
    }

    @Test("Older HUD attachment records decode without quote metadata")
    func legacyAttachment() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","url":"file:///tmp/synthetic.txt","filename":"synthetic.txt","byteCount":4,"isImage":false}
        """.utf8)
        #expect(try JSONDecoder().decode(HerdrHudAttachment.self, from: data).quote == nil)
    }

    @Test("Native conversation text remains read-only and selectable with bounded layout")
    func selectableLayout() async throws {
        let root = ChatSelectableText(text: PiMarkdownText.render("A **bold** answer with `code` and 👋🏽."), font: .system(size: 15))
            .environment(\.saveChatQuote, { _ in })
            .frame(width: 320)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ChatSelectionTextView? {
            if let text = view as? ChatSelectionTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        #expect(text.isSelectable)
        #expect(!text.isEditable)
        #expect(text.saveQuote != nil)
        #expect(text.string.contains("👋🏽"))
        text.setSelectedRange((text.string as NSString).range(of: "bold"))
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "bold")
        #expect(host.fittingSize.height > 0)
        #expect(host.fittingSize.height < 160)
    }
}
