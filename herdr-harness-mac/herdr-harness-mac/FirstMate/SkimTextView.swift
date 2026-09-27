import AppKit
import SwiftUI

/// Generated skim text with dotted anchors. Anchors are TextKit links
/// (`herdr-skim://anchor/a3`) so they wrap inline; hover shows a preview after
/// the delay, a click (or Return on the keyboard-focused anchor) opens the
/// exact original in a popover. Quoting stays on the full reply, never here.
struct SkimTextView: NSViewRepresentable {
    let tokens: [SkimToken]
    let interaction: SkimInteraction
    var fontSize: CGFloat = 15
    var lineHeight: CGFloat = 24
    var textColor: Color? = nil
    @Environment(\.self) private var environment
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.herdrFontScale) private var fontScale

    static let scheme = "herdr-skim"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SkimTextLayoutView {
        let view = SkimTextLayoutView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textView.delegate = context.coordinator
        return view
    }

    func updateNSView(_ layoutView: SkimTextLayoutView, context: Context) {
        let view = layoutView.textView
        context.coordinator.interaction = interaction
        view.interaction = interaction
        view.reduceMotion = environment.accessibilityReduceMotion
        let ink = NSColor(textColor ?? palette.text)
        let accent = NSColor(palette.accent)
        view.anchorInk = ink
        view.accent = accent
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        let size = fontSize * fontScale.rawValue
        let font = NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = HerdrProse.lineSpacing(size: fontSize, lineHeight: lineHeight, scale: fontScale)
        let result = NSMutableAttributedString()
        var anchors: [String: NSRange] = [:]
        func append(_ token: SkimToken, anchorID: String?) {
            switch token {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: ink]))
            case .code(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: (size * 0.86).rounded(), weight: .regular),
                    .foregroundColor: NSColor(palette.code),
                    .backgroundColor: NSColor(palette.codeFill),
                ]))
            case .anchor(let id, let label, _):
                let start = result.length
                for part in label { append(part, anchorID: id) }
                let range = NSRange(location: start, length: result.length - start)
                guard range.length > 0, let url = URL(string: "\(Self.scheme)://anchor/\(id)") else { return }
                result.addAttributes([
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
                    .underlineColor: ink.withAlphaComponent(0.55),
                ], range: range)
                anchors[id] = range
            }
        }
        for token in tokens { append(token, anchorID: nil) }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        view.anchorRanges = anchors
        layoutView.setAttributedText(result)
        interaction.register(view, anchors: Array(anchors.keys))
        view.refreshAnchorStyles()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SkimTextLayoutView, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width)
    }

    static func dismantleNSView(_ view: SkimTextLayoutView, coordinator: Coordinator) {
        view.textView.endHover()
        view.textView.interaction?.hidePreview()
        view.textView.delegate = nil
        coordinator.interaction?.unregister(view.textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var interaction: SkimInteraction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
                  url.scheme == SkimTextView.scheme, let view = textView as? SkimAnchorTextView else { return false }
            view.endHover()
            interaction?.open(anchorID: url.lastPathComponent, from: view)
            return true
        }
    }
}

/// SwiftUI owns the frame; measurement uses a separate TextKit stack, like
/// `ChatTextLayoutView`, so size negotiation never resizes the visible text.
final class SkimTextLayoutView: NSView {
    let textView = SkimAnchorTextView()
    private let measuringStorage = NSTextStorage()
    private let measuringLayout = NSLayoutManager()
    private let measuringContainer = NSTextContainer()
    private var heightCache: [CGFloat: CGFloat] = [:]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)
        measuringContainer.lineFragmentPadding = 0
        measuringStorage.addLayoutManager(measuringLayout)
        measuringLayout.addTextContainer(measuringContainer)
    }

    required init?(coder: NSCoder) { nil }

    func setAttributedText(_ text: NSAttributedString) {
        guard textView.attributedString() != text else { return }
        textView.textStorage?.setAttributedString(text)
        measuringStorage.setAttributedString(text)
        heightCache.removeAll(keepingCapacity: true)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func measuredSize(width proposedWidth: CGFloat?) -> NSSize {
        let width = max(1, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 600)
        if let height = heightCache[width] { return NSSize(width: width, height: height) }
        measuringContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        measuringLayout.ensureLayout(for: measuringContainer)
        let height = ceil(measuringLayout.usedRect(for: measuringContainer).maxY)
        if heightCache.count >= 8 { heightCache.removeAll(keepingCapacity: true) }
        heightCache[width] = height
        return NSSize(width: width, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutText()
    }

    override func layout() {
        super.layout()
        layoutText()
    }

    private func layoutText() {
        textView.frame = bounds
        textView.textContainer?.containerSize = NSSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)
    }
}

/// Hover, keyboard focus, and open-state styling for skim anchors.
final class SkimAnchorTextView: NSTextView {
    weak var interaction: SkimInteraction?
    var anchorRanges: [String: NSRange] = [:]
    var anchorInk: NSColor = .labelColor
    var accent: NSColor = .controlAccentColor
    var reduceMotion = false
    private(set) var hoveredAnchor: String?
    private(set) var focusedAnchor: String?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(anchor(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        interaction?.hidePreview()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 48 {
            moveFocus(forward: !event.modifierFlags.contains(.shift), fromEdge: true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        focusedAnchor = nil
        refreshAnchorStyles()
        interaction?.hidePreview()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab moves between anchors, then on to the next control.
            if !moveFocus(forward: !event.modifierFlags.contains(.shift), fromEdge: focusedAnchor == nil) {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            }
        case 36, 76, 49: // Return, Enter, Space open the focused anchor.
            if let focusedAnchor {
                interaction?.hidePreview()
                interaction?.open(anchorID: focusedAnchor, from: self)
            } else {
                super.keyDown(with: event)
            }
        case 53:
            interaction?.closeAll()
        default:
            super.keyDown(with: event)
        }
    }

    /// Keyboard focus previews the anchor, like hover does.
    @discardableResult
    private func moveFocus(forward: Bool, fromEdge: Bool) -> Bool {
        let ordered = anchorRanges.sorted { $0.value.location < $1.value.location }.map(\.key)
        guard !ordered.isEmpty else { return false }
        let next: String?
        if fromEdge || focusedAnchor == nil {
            next = forward ? ordered.first : ordered.last
        } else if let index = ordered.firstIndex(of: focusedAnchor!) {
            let target = index + (forward ? 1 : -1)
            next = ordered.indices.contains(target) ? ordered[target] : nil
        } else {
            next = nil
        }
        focusedAnchor = next
        refreshAnchorStyles()
        if let next, let rect = rect(for: next) {
            interaction?.showPreview(anchorID: next, from: self, rect: rect, delay: 0)
        } else {
            interaction?.hidePreview()
        }
        return next != nil
    }

    func endHover() {
        if hoveredAnchor != nil {
            hoveredAnchor = nil
            refreshAnchorStyles()
        }
    }

    private func setHovered(_ id: String?) {
        guard id != hoveredAnchor else { return }
        hoveredAnchor = id
        refreshAnchorStyles()
        guard let id, let rect = rect(for: id) else {
            interaction?.hidePreview()
            return
        }
        interaction?.showPreview(anchorID: id, from: self, rect: rect, delay: 0.15)
    }

    /// Rest: dotted ink at 55%. Hover or focus: lavender underline and a 13%
    /// tint. Open: solid underline and a 17% tint.
    func refreshAnchorStyles() {
        guard let layoutManager, let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        for (id, range) in anchorRanges where NSMaxRange(range) <= storage.length {
            if interaction?.openAnchorID == id {
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: accent.withAlphaComponent(0.17), .underlineColor: accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], forCharacterRange: range)
            } else if id == hoveredAnchor || id == focusedAnchor {
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: accent.withAlphaComponent(0.13), .underlineColor: accent,
                ], forCharacterRange: range)
            }
        }
    }

    func rect(for anchorID: String) -> NSRect? {
        guard let range = anchorRanges[anchorID], let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var first: NSRect?
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textContainer) { rect, stop in
            first = rect
            stop.pointee = true
        }
        return first.map { $0.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y) }
    }

    private func anchor(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, !anchorRanges.isEmpty else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return anchorRanges.first { NSLocationInRange(character, $0.value) }?.key
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        interaction?.hidePreview()
        return super.menu(for: event)
    }
}
