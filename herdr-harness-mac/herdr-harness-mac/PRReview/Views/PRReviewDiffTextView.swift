import AppKit
import SwiftUI

struct PRReviewLineIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var utf16Offset: Int
        var length: Int
        var gutterLength: Int = 0
        var side: PRReviewSide?
        var oldLine: Int?
        var newLine: Int?
        var kind: String
    }

    var entries: [Entry]

    func selection(path: String, oldPath: String, text: NSString, range: NSRange) -> PRReviewSelection? {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let selected = entries.filter { entry in
            entry.side != nil && NSIntersectionRange(entry.range, range).length > 0
        }
        guard !selected.isEmpty else { return nil }

        var spans: [PRReviewSelection.Span] = []
        var selectedLines: [String] = []
        for entry in selected {
            guard let side = entry.side,
                  let line = side == .before ? entry.oldLine : entry.newLine
            else { continue }
            if let last = spans.last, last.side == side, last.end + 1 == line {
                spans[spans.count - 1].end = line
            } else {
                spans.append(.init(side: side, start: line, end: line))
            }

            let selectedRange = NSIntersectionRange(entry.range, range)
            let codeRange = NSRange(
                location: entry.utf16Offset + entry.gutterLength,
                length: max(0, entry.length - entry.gutterLength - 1)
            )
            let selectedCode = NSIntersectionRange(selectedRange, codeRange)
            selectedLines.append(selectedCode.length > 0 ? text.substring(with: selectedCode) : "")
        }
        guard !spans.isEmpty else { return nil }
        return PRReviewSelection(
            path: path,
            oldPath: oldPath,
            spans: spans,
            text: selectedLines.joined(separator: "\n")
        )
    }
}

private extension PRReviewLineIndex.Entry {
    var range: NSRange {
        NSRange(location: utf16Offset, length: length)
    }
}

final class PRReviewDiffTextView: NSTextView, NSPopoverDelegate {
    var lineIndex = PRReviewLineIndex(entries: [])
    var selectionPath = ""
    var selectionOldPath = ""
    var highlight: (start: Int, end: Int, side: PRReviewSide)?
    var askAI: ((PRReviewSelection, NSView, CGRect) -> Void)?
    var questionDraftChanged: ((Bool) -> Void)?
    var askPopover: NSPopover?
    private var endpoint: CGPoint?
    private var flashedRange: NSRange?
    private var flashTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        askPopover?.close()
        super.mouseDown(with: event)
        if let window {
            endpoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        }
        showAskAction()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        endpoint = convert(event.locationInWindow, from: nil)
        if selectedSelection != nil {
            let item = NSMenuItem(title: "Ask AI about selection…", action: #selector(showQuestionPopover), keyEquivalent: "")
            item.target = self
            menu?.insertItem(item, at: 0)
        }
        return menu
    }

    override func drawBackground(in rect: NSRect) {
        guard let layoutManager, let textContainer else {
            super.drawBackground(in: rect)
            return
        }

        for entry in lineIndex.entries {
            guard let color = rowColor(for: entry.kind) else { continue }
            drawFullWidthBackground(
                color: color.withAlphaComponent(0.16),
                glyphRange: layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil),
                textContainer: textContainer
            )
        }
        if let highlight {
            let matching = lineIndex.entries.filter { entry in
                guard entry.side == highlight.side else { return false }
                let line = highlight.side == .before ? entry.oldLine : entry.newLine
                return line.map { highlight.start...highlight.end ~= $0 } ?? false
            }
            drawHighlight(matching, layoutManager: layoutManager, textContainer: textContainer)
        }
        if let flashedRange {
            drawFullWidthBackground(
                color: NSColor(HerdrTheme.accent).withAlphaComponent(0.24),
                glyphRange: layoutManager.glyphRange(forCharacterRange: flashedRange, actualCharacterRange: nil),
                textContainer: textContainer
            )
        }
        super.drawBackground(in: rect)
    }

    func scrollToLine(_ line: Int, side: PRReviewSide) {
        guard let entry = lineIndex.entries.first(where: { entry in
            entry.side == side && (side == .before ? entry.oldLine : entry.newLine) == line
        }) else { return }
        scrollRangeToVerticalCenter(entry.range)
        flash(entry.range)
    }

    func isLineVisible(_ line: Int, side: PRReviewSide) -> Bool {
        guard let entry = lineIndex.entries.first(where: { entry in
            entry.side == side && (side == .before ? entry.oldLine : entry.newLine) == line
        }), let layoutManager, textContainer != nil else { return false }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
        var isVisible = false
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            let rect = usedRect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            isVisible = isVisible || rect.intersects(self.visibleRect)
        }
        return isVisible
    }

    func popoverDidClose(_ notification: Notification) {
        questionDraftChanged?(false)
        askPopover = nil
    }

    private var selectedSelection: PRReviewSelection? {
        lineIndex.selection(path: selectionPath, oldPath: selectionOldPath, text: string as NSString, range: selectedRange())
    }

    private func showAskAction() {
        guard selectedSelection != nil, let anchor = selectionAnchor() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            Button("Ask AI…", systemImage: "sparkles") { [weak self] in
                self?.showQuestionPopover()
            }
            .buttonStyle(.plain)
            .herdrFont(.callout)
            .padding(10)
            .foregroundStyle(HerdrTheme.text)
            .background(HerdrTheme.graphite)
            .preferredColorScheme(.dark)
        )
        askPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    @objc private func showQuestionPopover() {
        guard let selection = selectedSelection, let anchor = selectionAnchor() else { return }
        askPopover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 380, height: 250)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PRReviewAskPopover(
            selection: selection,
            send: { [weak self] question in
                guard let self else { return }
                self.questionDraftChanged?(false)
                self.askPopover?.close()
                var questionSelection = selection
                questionSelection.question = question
                self.askAI?(questionSelection, self, anchor)
            },
            dismiss: { [weak self] in self?.askPopover?.close() },
            draftChanged: { [weak self] isNonEmpty in self?.questionDraftChanged?(isNonEmpty) }
        ))
        askPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    private func selectionAnchor() -> CGRect? {
        guard let layoutManager, let textContainer, selectedRange().length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var rectangles: [CGRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: glyphs,
            in: textContainer
        ) { rect, _ in
            rectangles.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return ChatQuoteAnchor.rect(selectionRects: rectangles, visibleRect: visibleRect, preferredPoint: endpoint)
    }

    private func rowColor(for kind: String) -> NSColor? {
        switch kind {
        case "add": NSColor(HerdrTheme.diffAdd)
        case "del": NSColor(HerdrTheme.diffRemove)
        case "hunk": NSColor(HerdrTheme.diffHunk)
        default: nil
        }
    }

    private func drawFullWidthBackground(color: NSColor, glyphRange: NSRange, textContainer: NSTextContainer) {
        guard let layoutManager else { return }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            let origin = self.textContainerOrigin
            let fragment = usedRect.offsetBy(dx: origin.x, dy: origin.y)
            color.setFill()
            NSRect(x: 0, y: fragment.minY, width: self.bounds.width, height: fragment.height).fill()
        }
    }

    private func drawHighlight(_ entries: [PRReviewLineIndex.Entry], layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        var union: NSRect?
        for entry in entries {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                let rect = usedRect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                union = union.map { $0.union(rect) } ?? rect
            }
        }
        guard let union else { return }
        let ring = union.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: ring, xRadius: HerdrTheme.compactRadius, yRadius: HerdrTheme.compactRadius)
        NSColor(HerdrTheme.accent).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func scrollRangeToVerticalCenter(_ range: NSRange) {
        guard let layoutManager, textContainer != nil, let clipView = enclosingScrollView?.contentView else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let targetY = fragment.midY + textContainerOrigin.y - clipView.bounds.height / 2
        let maximumY = max(0, bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: min(max(0, targetY), maximumY)))
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    private func flash(_ range: NSRange) {
        flashedRange = range
        needsDisplay = true
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flashedRange = nil
                self?.needsDisplay = true
            }
        }
    }
}

struct PRReviewDiffText: NSViewRepresentable {
    let file: PRReviewDiffFile
    var headSHA = ""
    @Environment(\.herdrFontScale) private var fontScale
    var highlight: (start: Int, end: Int, side: PRReviewSide)?
    var scrollRequest: (path: String, line: Int, side: PRReviewSide, token: Int)?
    var askAI: ((PRReviewSelection, NSView, CGRect) -> Void)?
    var questionDraftChanged: ((Bool) -> Void)?
    var onVisibleLinesChange: ((String, Int, Int, PRReviewSide) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PRReviewDiffTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(HerdrTheme.graphite)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 8
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.selectedTextAttributes = [.backgroundColor: NSColor(HerdrTheme.accent).withAlphaComponent(0.3)]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.install(on: scroll, textView: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PRReviewDiffTextView else { return }
        let identity = Coordinator.RenderIdentity(
            path: file.path,
            oldPath: file.oldPath,
            headSHA: headSHA,
            fontScale: fontScale
        )
        if context.coordinator.shouldSetAttributedString(for: identity) {
            let rendered = PRReviewDiffRenderer.render(file: file, fontScale: fontScale)
            textView.textStorage?.setAttributedString(rendered.text)
            textView.lineIndex = rendered.index
            context.coordinator.lastRenderedIdentity = identity
        }
        textView.selectionPath = file.path
        textView.selectionOldPath = file.oldPath ?? ""
        textView.highlight = highlight
        textView.askAI = askAI
        textView.questionDraftChanged = questionDraftChanged
        textView.needsDisplay = true
        context.coordinator.configure(path: file.path, onVisibleLinesChange: onVisibleLinesChange)
        if let scrollRequest, scrollRequest.path == file.path, context.coordinator.lastScrollToken != scrollRequest.token {
            context.coordinator.lastScrollToken = scrollRequest.token
            DispatchQueue.main.async {
                textView.scrollToLine(scrollRequest.line, side: scrollRequest.side)
                context.coordinator.scheduleVisibleLinesUpdate()
            }
        }
        context.coordinator.scheduleVisibleLinesUpdate()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        (scroll.documentView as? PRReviewDiffTextView)?.askPopover?.close()
    }

    @MainActor
    final class Coordinator: NSObject {
        struct RenderIdentity: Equatable {
            let path: String
            let oldPath: String?
            let headSHA: String
            let fontScale: HerdrFontScale
        }

        var lastScrollToken: Int?
        var lastRenderedIdentity: RenderIdentity?
        private weak var scrollView: NSScrollView?
        private weak var textView: PRReviewDiffTextView?
        private var boundsObserver: NSObjectProtocol?
        private var visibilityTask: Task<Void, Never>?
        private var path = ""
        private var onVisibleLinesChange: ((String, Int, Int, PRReviewSide) -> Void)?

        func shouldSetAttributedString(for identity: RenderIdentity) -> Bool {
            lastRenderedIdentity != identity
        }

        func install(on scrollView: NSScrollView, textView: PRReviewDiffTextView) {
            self.scrollView = scrollView
            self.textView = textView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleVisibleLinesUpdate()
                }
            }
        }

        func configure(
            path: String,
            onVisibleLinesChange: ((String, Int, Int, PRReviewSide) -> Void)?
        ) {
            self.path = path
            self.onVisibleLinesChange = onVisibleLinesChange
        }

        func scheduleVisibleLinesUpdate() {
            visibilityTask?.cancel()
            visibilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.reportVisibleLines()
            }
        }

        func invalidate() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            visibilityTask?.cancel()
        }

        private func reportVisibleLines() {
            guard let textView, let layoutManager = textView.layoutManager, textView.textContainer != nil else { return }
            let visible = textView.visibleRect
            let visibleEntries = textView.lineIndex.entries.filter { entry in
                guard entry.kind != "hunk", entry.side != nil else { return false }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
                let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                return fragment.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y).intersects(visible)
            }
            guard let first = visibleEntries.first, let side = first.side else { return }
            let lines = visibleEntries.compactMap { entry -> Int? in
                guard entry.side == side else { return nil }
                return side == .before ? entry.oldLine : entry.newLine
            }
            guard let start = lines.min(), let end = lines.max() else { return }
            onVisibleLinesChange?(path, start, end, side)
        }
    }
}

enum PRReviewDiffRenderer {
    static func render(
        file: PRReviewDiffFile,
        fontScale: HerdrFontScale = .medium
    ) -> (text: NSAttributedString, index: PRReviewLineIndex) {
        let result = NSMutableAttributedString()
        var entries: [PRReviewLineIndex.Entry] = []
        let font = NSFont.monospacedSystemFont(ofSize: 13 * fontScale.rawValue, weight: .regular)
        let gutterColor = NSColor(HerdrTheme.muted)

        func append(
            gutter: String,
            code: String,
            side: PRReviewSide?,
            old: Int?,
            new: Int?,
            kind: String,
            codeColor: NSColor
        ) {
            let offset = result.length
            result.append(NSAttributedString(string: gutter, attributes: [.font: font, .foregroundColor: gutterColor]))
            result.append(NSAttributedString(string: code + "\n", attributes: [.font: font, .foregroundColor: codeColor]))
            entries.append(.init(
                utf16Offset: offset,
                length: ((gutter + code + "\n") as NSString).length,
                gutterLength: (gutter as NSString).length,
                side: side,
                oldLine: old,
                newLine: new,
                kind: kind
            ))
        }

        for hunk in file.hunks {
            append(gutter: "", code: hunk.header, side: nil, old: nil, new: nil, kind: "hunk", codeColor: NSColor(HerdrTheme.diffHunk))
            for line in hunk.lines {
                let side: PRReviewSide? = line.kind == "del" ? .before : .after
                let old = line.oldNumber.map(String.init) ?? ""
                let new = line.newNumber.map(String.init) ?? ""
                let gutter = old.padding(toLength: 4, withPad: " ", startingAt: 0)
                    + " │ " + new.padding(toLength: 4, withPad: " ", startingAt: 0) + "  "
                let prefix = line.kind == "add" ? "+" : line.kind == "del" ? "-" : " "
                let color: NSColor
                switch line.kind {
                case "add": color = NSColor(HerdrTheme.diffAdd)
                case "del": color = NSColor(HerdrTheme.diffRemove)
                default: color = NSColor(HerdrTheme.text)
                }
                append(gutter: gutter, code: prefix + line.text, side: side, old: line.oldNumber, new: line.newNumber,
                       kind: line.kind, codeColor: color)
            }
        }
        return (result, PRReviewLineIndex(entries: entries))
    }
}
