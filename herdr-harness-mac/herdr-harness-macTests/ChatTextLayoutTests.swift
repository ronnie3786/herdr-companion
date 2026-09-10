import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Native chat text layout", .serialized)
@MainActor
struct ChatTextLayoutTests {
    private let paragraph = "The conversation should use the available reading width. Selecting an excerpt must not change line wrapping or allow text to draw over the next paragraph, tool group, or message. "

    @Test("Native paragraphs fit their allocated rows across window resizing", arguments: [HerdrFontScale.medium, .xxxLarge])
    func multiParagraphResize(scale: HerdrFontScale) async throws {
        let model = LayoutFixtureModel()
        model.source = Array(repeating: paragraph, count: 3).joined() + "\n\n" + paragraph
        let root = LayoutFixtureView(model: model, scale: scale)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for width: CGFloat in [1200, 620, 1450, 900] {
            window.setContentSize(NSSize(width: width, height: 900))
            for _ in 0..<6 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            try assertLayout(in: host, minimumWidth: min(width - 100, 700))
        }
        // Grow a mounted streaming reply, then finalize it into Markdown blocks.
        model.streaming = true
        model.source += "\n\n" + Array(repeating: paragraph, count: 4).joined()
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try assertLayout(in: host, minimumWidth: 700)
        model.streaming = false
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try assertLayout(in: host, minimumWidth: 700)
    }

    @Test("Measuring speculative widths never changes displayed wrapping or selection")
    func isolatedMeasurement() throws {
        let view = ChatTextLayoutView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let source = NSAttributedString(string: Array(repeating: paragraph, count: 4).joined(),
                                        attributes: [.font: NSFont.systemFont(ofSize: 15)])
        view.setAttributedText(source)
        view.layout()
        let selected = (source.string as NSString).range(of: "Selecting")
        view.textView.setSelectedRange(selected)
        let displayedFrame = view.textView.frame
        let displayedWidth = try #require(view.textView.textContainer).containerSize.width
        let wide = view.measuredSize(width: 900)
        let narrow = view.measuredSize(width: 300)
        #expect(narrow.height > wide.height)
        #expect(view.measuredSize(width: 900) == wide)
        #expect(view.measuredSize(width: .infinity).height.isFinite)
        #expect(view.textView.frame == displayedFrame)
        #expect(view.textView.textContainer?.containerSize.width == displayedWidth)
        #expect(view.textView.selectedRange() == selected)
        #expect(!view.textView.isVerticallyResizable)
        view.setAttributedText(NSAttributedString(string: "Short reply", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        #expect(view.measuredSize(width: 900).height < wide.height)
    }

    @Test("Multiline chat renders without overlapping paragraphs or tool cards")
    func rendersMultilineChat() async throws {
        let model = LayoutFixtureModel()
        model.source = Array(repeating: paragraph, count: 2).joined() + "\n\n" + paragraph
        for width: CGFloat in [620, 1200] {
            let render = try await HerdrRenderHarness.render("chat-layout-\(Int(width)).png", size: CGSize(width: width, height: 900)) {
                LayoutFixtureView(model: model)
            }
            render.expectSubstantial()
        }
    }

    private func assertLayout(in host: NSView, minimumWidth: CGFloat) throws {
        let texts = descendants(host).compactMap { $0 as? ChatSelectionTextView }
        #expect(texts.count >= 4)
        for text in texts {
            let container = try #require(text.textContainer)
            let layout = try #require(text.layoutManager)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            #expect(text.bounds.width >= minimumWidth, "Text narrowed to \(text.bounds.width); expected at least \(minimumWidth)")
            #expect(abs(container.containerSize.width - text.bounds.width) < 1,
                    "Measured text container and displayed text view disagree")
            #expect(ceil(used.maxY) <= ceil(text.bounds.height) + 1,
                    "Glyph height \(used.maxY) exceeds allocated row height \(text.bounds.height)")
        }
        let rectangles = texts.map { $0.convert($0.bounds, to: host) }
        for index in rectangles.indices {
            for other in rectangles.indices where other > index {
                let overlap = rectangles[index].intersection(rectangles[other])
                #expect(overlap.isNull || overlap.height < 1 || overlap.width < 1, "Chat paragraphs overlap")
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable
private final class LayoutFixtureModel {
    var source = ""
    var streaming = false
}

private struct LayoutFixtureView: View {
    let model: LayoutFixtureModel
    var scale: HerdrFontScale = .medium
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<3) { index in
                    PiAssistantMessageView(block: PiAssistantBlock(id: "layout-\(index)", text: model.source,
                                                                   status: model.streaming ? .streaming : .complete))
                    Text("Clanking · 3 steps · Complete")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).border(.gray)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .environment(\.saveChatQuote, { _ in })
        .environment(\.herdrFontScale, scale)
    }
}
