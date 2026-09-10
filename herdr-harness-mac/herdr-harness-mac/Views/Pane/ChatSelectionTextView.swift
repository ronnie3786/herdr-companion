import AppKit
import SwiftUI

final class ChatSelectionTextView: NSTextView {
    var saveQuote: (@MainActor (ChatQuote) async throws -> Void)?
    var quoteSource = "Chat"
    var quoteFontScale = HerdrFontScale.medium
    var reduceMotion = false
    var quotePopover: NSPopover?

    override func mouseDown(with event: NSEvent) {
        quotePopover?.close()
        super.mouseDown(with: event)
        // NSTextView tracks the complete drag inside mouseDown.
        if selectedRange().length > 0 { showQuoteAction() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
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
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        guard let window else { return }
        let anchor = convert(window.convertFromScreen(screenRect), from: nil).intersection(visibleRect)
        guard !visibleRect.isEmpty else { return }
        popover.animates = !reduceMotion
        popover.show(relativeTo: anchor.isNull ? visibleRect : anchor, of: self, preferredEdge: .maxY)
    }
}
