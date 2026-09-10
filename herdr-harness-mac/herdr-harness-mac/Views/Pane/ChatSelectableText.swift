import AppKit
import SwiftUI

/// Native selection gives both prompt bubbles and Markdown the same Copy and
/// quote behavior. TextKit measures at the proposed width; no nested scroll view.
struct ChatSelectableText: NSViewRepresentable {
    let text: AttributedString
    let font: Font
    var lineSpacing: CGFloat = 3
    @Environment(\.self) private var environment
    @Environment(\.saveChatQuote) private var saveQuote
    @Environment(\.chatQuoteSource) private var source

    func makeNSView(context: Context) -> ChatTextLayoutView {
        let view = ChatTextLayoutView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textView.linkTextAttributes = [.foregroundColor: NSColor(HerdrTheme.accent)]
        view.textView.selectedTextAttributes = [.backgroundColor: NSColor(HerdrTheme.accent).withAlphaComponent(0.3)]
        return view
    }

    func updateNSView(_ layoutView: ChatTextLayoutView, context: Context) {
        let view = layoutView.textView
        let baseFont = font.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let result = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let fullRange = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        result.addAttributes([.font: baseFont, .foregroundColor: NSColor(HerdrTheme.text), .paragraphStyle: paragraph], range: fullRange)
        for run in text.runs {
            let range = NSRange(run.range, in: text)
            var runFont = run.font.map { $0.resolve(in: environment.fontResolutionContext).ctFont as NSFont } ?? baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            }
            result.addAttribute(.font, value: runFont, range: range)
            if let color = run.foregroundColor { result.addAttribute(.foregroundColor, value: NSColor(color), range: range) }
        }
        layoutView.setAttributedText(result)
        view.saveQuote = saveQuote
        view.quoteSource = source
        view.quoteFontScale = environment.herdrFontScale
        view.reduceMotion = environment.accessibilityReduceMotion
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatTextLayoutView, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width)
    }

    static func dismantleNSView(_ view: ChatTextLayoutView, coordinator: ()) {
        view.textView.quotePopover?.close()
    }
}
