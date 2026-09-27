import AppKit
import SwiftUI

/// One rendered skim's interaction state: which text view shows which anchor,
/// the open card, and how a card reveals blocks in the full reply.
@MainActor
final class SkimInteraction {
    let messageID: String
    private(set) var reader: FirstMateSkimReader
    /// Opens the full reply scrolled to (and highlighting) these segment ids.
    var reveal: ([String]) -> Void = { _ in }
    /// Reports whether this message has a card open (a ready skim waits for it).
    var openStateChanged: (Bool) -> Void = { _ in }
    var colorScheme: ColorScheme = .dark
    var fontScale: HerdrFontScale = .medium
    var reduceMotion = false
    var palette: ChatProsePalette = .chat
    private(set) var openAnchorID: String?
    private var views: [ObjectIdentifier: (view: WeakTextView, anchors: [String])] = [:]

    init(messageID: String, reader: FirstMateSkimReader) {
        self.messageID = messageID
        self.reader = reader
    }

    func update(reader: FirstMateSkimReader) {
        guard reader != self.reader else { return }
        self.reader = reader
        SkimPopoverCenter.shared.close(owner: self)
    }

    func register(_ view: SkimAnchorTextView, anchors: [String]) {
        views[ObjectIdentifier(view)] = (WeakTextView(view: view), anchors)
    }

    func unregister(_ view: NSTextView) {
        views.removeValue(forKey: ObjectIdentifier(view))
    }

    var isOpen: Bool { SkimPopoverCenter.shared.isOpen(owner: self) }

    // MARK: - Cards

    func showPreview(anchorID: String, from view: SkimAnchorTextView, rect: NSRect, delay: TimeInterval) {
        guard let anchor = reader.anchor(anchorID), !isOpen else { return }
        let preview = reader.preview(for: anchor.refs, kind: anchor.kind)
        SkimPopoverCenter.shared.preview(SkimPreviewCard(preview: preview, hint: "Click to open the original"),
                                         wide: preview.isWide, owner: self, view: view, rect: rect, delay: delay)
    }

    func showPreview(refs: [String], hint: String, from view: NSView) {
        guard !isOpen else { return }
        let kind = refs.compactMap(reader.segment).first(where: { ["code", "table"].contains($0.kind) })?.kind ?? "text"
        let preview = reader.preview(for: refs, kind: kind)
        SkimPopoverCenter.shared.preview(SkimPreviewCard(preview: preview, hint: hint), wide: preview.isWide,
                                         owner: self, view: view, rect: view.bounds, delay: 0.15)
    }

    func hidePreview() {
        SkimPopoverCenter.shared.hidePreview(owner: self)
    }

    func open(anchorID: String, from view: SkimAnchorTextView) {
        guard let anchor = reader.anchor(anchorID) else { return }
        let rect = view.rect(for: anchorID) ?? view.bounds
        present(refs: anchor.refs, title: anchor.label, anchorID: anchorID, view: view, rect: rect)
    }

    /// Opens an anchor from an accessibility action, wherever it is drawn.
    func open(anchorID: String) {
        for entry in views.values {
            if let view = entry.view.view, entry.anchors.contains(anchorID) {
                open(anchorID: anchorID, from: view)
                return
            }
        }
    }

    func openRest(from view: NSView) {
        present(refs: reader.restRefs, title: "Rest of the original", anchorID: nil, view: view, rect: view.bounds)
    }

    func closeAll() {
        SkimPopoverCenter.shared.close(owner: self)
    }

    private func present(refs: [String], title: String, anchorID: String?, view: NSView, rect: NSRect) {
        guard !refs.isEmpty else { return }
        let excerpt = SkimExcerptView(
            reader: reader, refs: refs, title: title,
            close: { [weak self] in self.map { SkimPopoverCenter.shared.close(owner: $0) } },
            showInReply: { [weak self] in
                guard let self else { return }
                SkimPopoverCenter.shared.close(owner: self)
                self.reveal(refs)
            }
        )
        openAnchorID = anchorID
        refreshStyles()
        openStateChanged(true)
        SkimPopoverCenter.shared.open(excerpt, wide: reader.isWide(refs), owner: self, view: view, rect: rect) { [weak self] in
            guard let self else { return }
            self.openAnchorID = nil
            self.refreshStyles()
            self.openStateChanged(false)
        }
    }

    private func refreshStyles() {
        for entry in views.values { entry.view.view?.refreshAnchorStyles() }
    }

    fileprivate func hosted<Content: View>(_ content: Content) -> some View {
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.herdrFontScale, fontScale)
            .environment(\.chatProsePalette, palette)
            .preferredColorScheme(colorScheme)
    }

    private struct WeakTextView {
        weak var view: SkimAnchorTextView?
    }
}

/// One skim card at a time across the app: a hover preview (never
/// interactive) or an open excerpt. Escape or an outside click closes it.
@MainActor
final class SkimPopoverCenter: NSObject, NSPopoverDelegate {
    static let shared = SkimPopoverCenter()

    private var previewPopover: NSPopover?
    private var previewOwner: ObjectIdentifier?
    private var pendingPreview: DispatchWorkItem?
    private var excerptPopover: NSPopover?
    private var excerptOwner: ObjectIdentifier?
    private var onExcerptClose: (() -> Void)?

    func isOpen(owner: SkimInteraction) -> Bool {
        excerptOwner == ObjectIdentifier(owner) && excerptPopover?.isShown == true
    }

    func preview<Content: View>(_ content: Content, wide: Bool, owner: SkimInteraction, view: NSView, rect: NSRect,
                                delay: TimeInterval) {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self, weak owner, weak view] in
            guard let self, let owner, let view, view.window != nil, self.excerptPopover?.isShown != true else { return }
            self.dismissPreview()
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            let controller = NSHostingController(rootView: owner.hosted(content.frame(width: wide ? 540 : 380)))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            popover.appearance = NSAppearance(named: owner.colorScheme == .dark ? .darkAqua : .aqua)
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            self.previewPopover = popover
            self.previewOwner = ObjectIdentifier(owner)
        }
        pendingPreview = work
        if delay <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func hidePreview(owner: SkimInteraction) {
        pendingPreview?.cancel()
        pendingPreview = nil
        if previewOwner == ObjectIdentifier(owner) { dismissPreview() }
    }

    private func dismissPreview() {
        previewPopover?.close()
        previewPopover = nil
        previewOwner = nil
    }

    func open<Content: View>(_ content: Content, wide: Bool, owner: SkimInteraction, view: NSView, rect: NSRect,
                             onClose: @escaping () -> Void) {
        pendingPreview?.cancel()
        dismissPreview()
        closeExcerpt()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !owner.reduceMotion
        popover.delegate = self
        let controller = NSHostingController(rootView: owner.hosted(content.frame(width: wide ? 760 : 560)))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.appearance = NSAppearance(named: owner.colorScheme == .dark ? .darkAqua : .aqua)
        excerptPopover = popover
        excerptOwner = ObjectIdentifier(owner)
        onExcerptClose = onClose
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close(owner: SkimInteraction) {
        if previewOwner == ObjectIdentifier(owner) {
            pendingPreview?.cancel()
            dismissPreview()
        }
        if excerptOwner == ObjectIdentifier(owner) { closeExcerpt() }
    }

    private func closeExcerpt() {
        guard let popover = excerptPopover else { return }
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === excerptPopover else { return }
        excerptPopover = nil
        excerptOwner = nil
        let callback = onExcerptClose
        onExcerptClose = nil
        callback?()
    }
}
