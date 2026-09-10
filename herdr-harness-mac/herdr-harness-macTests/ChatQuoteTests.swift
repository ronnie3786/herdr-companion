import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Chat quotes", .serialized)
@MainActor
struct ChatQuoteTests {
    @Test("Quote attachments preserve Unicode, multiline excerpts, provenance and comments")
    func markdownAttachment() throws {
        let quote = ChatQuote(text: "Hello 👋🏽\nlet café = 1", comment: "Explain this example.", source: "Pi session synthetic-session")
        let url = try quote.writeAttachment()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("> Hello 👋🏽\n> let café = 1"))
        #expect(text.contains("Explain this example."))
        #expect(text.contains("synthetic-session"))
        #expect(try JSONDecoder().decode(ChatQuote.self, from: JSONEncoder().encode(quote)) == quote)
        #expect(try AttachmentPolicy.candidate(for: url, ownership: .appTemporary).byteCount > 0)
    }

    @Test("HUD quote Save stages context without sending or modifying the draft")
    func hudStagesQuote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = HerdrHudSession(userDefaults: defaults, persistenceURL: root.appendingPathComponent("hud.json"))
        session.draft = "My next question"
        let quote = ChatQuote(text: "An earlier response", comment: "Check this detail", source: "HUD exchange example")
        try session.addQuote(quote)
        #expect(session.draft == "My next question")
        #expect(session.exchanges.isEmpty)
        #expect(!session.isRunning)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.quote == quote)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
        #expect(try JSONDecoder().decode(HerdrHudAttachment.self, from: JSONEncoder().encode(attachment)).quote == quote)
        session.removeAttachment(attachment.id)
        #expect(session.pendingAttachments.isEmpty)
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
