import AppKit

/// SwiftUI owns this view's frame. The NSTextView must not resize itself or
/// borrow the last width SwiftUI happened to probe during size negotiation.
final class ChatTextLayoutView: NSView {
    let textView = ChatSelectionTextView()
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
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)

        measuringContainer.lineFragmentPadding = 0
        measuringContainer.widthTracksTextView = false
        measuringContainer.heightTracksTextView = false
        measuringStorage.addLayoutManager(measuringLayout)
        measuringLayout.addTextContainer(measuringContainer)
    }

    required init?(coder: NSCoder) { nil }

    func setAttributedText(_ text: NSAttributedString) {
        guard textView.attributedString() != text else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(text)
        if NSMaxRange(selection) <= text.length { textView.setSelectedRange(selection) }
        measuringStorage.setAttributedString(text)
        heightCache.removeAll(keepingCapacity: true)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Measurement uses a separate TextKit stack. SwiftUI may ask for several
    /// widths, out of order, without subsequently changing the displayed frame.
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
