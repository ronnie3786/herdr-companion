import AppKit
import SwiftUI

final class ChatSelectionTextView: NSTextView {
    var saveQuote: (@MainActor (ChatQuote) async throws -> Void)? {
        didSet { if saveQuote == nil { quotePopover?.close() } }
    }
    var quoteSource = "Chat"
    var quoteFontScale = HerdrFontScale.medium
    var reduceMotion = false
    var quotePopover: NSPopover?
    private var selectionEndpoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        quotePopover?.close()
        super.mouseDown(with: event)
        // NSTextView tracks the complete drag inside mouseDown. Preserve the
        // drag endpoint before the pointer moves onto the floating action.
        if let window {
            selectionEndpoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        }
        if selectedRange().length > 0 { showQuoteAction() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        selectionEndpoint = convert(event.locationInWindow, from: nil)
        if saveQuote != nil, selectedRange().length > 0 {
            let item = NSMenuItem(title: "Quote & comment…", action: #selector(editQuote), keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: 0)
        }
        return menu
    }

    private func selectedExcerpt() -> String? {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return nil }
        let excerpt = (string as NSString).substring(with: range)
        return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
    }

    private func showQuoteAction() {
        guard saveQuote != nil, selectedExcerpt() != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            Button("Quote & comment…", systemImage: "quote.bubble") { [weak self] in self?.editQuote() }
                .buttonStyle(.plain).herdrFont(.callout).padding(10)
                .foregroundStyle(HerdrTheme.text).background(HerdrTheme.graphite)
                .environment(\.herdrFontScale, quoteFontScale)
                .preferredColorScheme(.dark)
        )
        show(popover)
    }

    @objc private func editQuote() {
        guard let saveQuote, let excerpt = selectedExcerpt() else { return }
        let popover = NSPopover()
        // Don't dismiss on outside clicks while a comment is being drafted.
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: ChatQuoteEditor(
            text: excerpt, source: quoteSource, save: saveQuote,
            dismiss: { [weak self] in self?.quotePopover?.close() }
        ).environment(\.herdrFontScale, quoteFontScale))
        show(popover)
    }

    private func show(_ popover: NSPopover) {
        quotePopover?.close()
        quotePopover = popover
        guard window != nil, let anchor = quoteAnchor() else { return }
        popover.animates = !reduceMotion
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    func quoteAnchor() -> CGRect? {
        guard let layoutManager, let textContainer, selectedRange().length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var rectangles: [CGRect] = []
        let origin = textContainerOrigin
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer) { rect, _ in
            rectangles.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return ChatQuoteAnchor.rect(selectionRects: rectangles, visibleRect: visibleRect, preferredPoint: selectionEndpoint)
    }

    override func layout() {
        super.layout()
        if let quotePopover, quotePopover.isShown, let anchor = quoteAnchor() {
            quotePopover.positioningRect = anchor
        }
    }
}
