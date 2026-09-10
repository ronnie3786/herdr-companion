import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("Quote popup placement")
struct ChatQuoteAnchorTests {
    @Test("Multiline quote anchors at the selected line beside the drag endpoint")
    func multilineEndpoint() throws {
        let lines = [CGRect(x: 10, y: 10, width: 500, height: 18), CGRect(x: 10, y: 30, width: 400, height: 18)]
        let rect = try #require(ChatQuoteAnchor.rect(selectionRects: lines, visibleRect: CGRect(x: 0, y: 0, width: 600, height: 200), preferredPoint: CGPoint(x: 395, y: 39)))
        #expect(rect.minY == 30)
        #expect(abs(rect.midX - 395) <= 3)
        #expect(rect.width <= 6)
    }

    @Test("Offscreen selected lines do not move the popup to an unrelated view edge")
    func clippedSelection() throws {
        let lines = [CGRect(x: 0, y: 10, width: 200, height: 18), CGRect(x: 0, y: 200, width: 120, height: 18)]
        let viewport = CGRect(x: 0, y: 190, width: 400, height: 100)
        let rect = try #require(ChatQuoteAnchor.rect(selectionRects: lines, visibleRect: viewport, preferredPoint: CGPoint(x: 110, y: 209)))
        #expect(rect.minY == 200)
        #expect(rect.maxX <= 120)
        #expect(ChatQuoteAnchor.rect(selectionRects: [lines[0]], visibleRect: viewport, preferredPoint: nil) == nil)
    }

    @MainActor
    @Test("Native quote anchor stays inside the selected glyphs")
    func nativeGlyphs() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ChatTextLayoutView(frame: window.contentLayoutRect)
        window.contentView = view
        let source = "Unselected first line\n\nSelected phrase on a later line"
        view.setAttributedText(NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        view.layout()
        view.textView.setSelectedRange((source as NSString).range(of: "Selected phrase"))
        let anchor = try #require(view.textView.quoteAnchor())
        #expect(anchor.minY > 20)
        #expect(anchor.maxY < view.bounds.height)
        #expect(anchor.width <= 6)
    }
}
