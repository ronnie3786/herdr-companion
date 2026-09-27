import SwiftUI
import UIKit

/// A verbatim run split into prose (the host's Markdown renderer) and fenced
/// code (`SkimCodeBlockView`). Fences are found at any indentation, so a code
/// block nested in a list item still gets a real code block.
struct SkimExcerptPart: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case prose(String)
        case code(language: String?, code: String)
    }

    let id: Int
    let content: Content

    static func split(_ text: String) -> [SkimExcerptPart] {
        var contents: [Content] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if joined.contains(where: { !$0.isWhitespace }) { contents.append(.prose(joined)) }
            prose.removeAll()
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard let fence = opening(lines[index]) else {
                prose.append(lines[index])
                index += 1
                continue
            }
            flushProse()
            var block = [lines[index]]
            index += 1
            while index < lines.count {
                let line = lines[index]
                block.append(line)
                index += 1
                if closes(line, marker: fence.marker, count: fence.count) { break }
            }
            let code = FirstMateSkimReader.codeBody(block.joined(separator: "\n"))
            contents.append(.code(language: fence.language, code: code))
        }
        flushProse()
        return contents.enumerated().map { SkimExcerptPart(id: $0.offset, content: $0.element) }
    }

    private static func opening(_ line: String) -> (marker: Character, count: Int, language: String?)? {
        let content = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let info = content.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (marker, count, info.split(whereSeparator: \.isWhitespace).first.map(String.init))
    }

    private static func closes(_ line: String, marker: Character, count: Int) -> Bool {
        let content = line.drop { $0 == " " || $0 == "\t" }
        let run = content.prefix { $0 == marker }.count
        return run >= count && content.dropFirst(run).allSatisfy(\.isWhitespace)
    }
}

/// One verbatim run, rendered like the host's reply except for code blocks.
struct SkimExcerptRunContent: View {
    let style: SkimStyle
    private let parts: [SkimExcerptPart]

    init(text: String, style: SkimStyle) {
        self.style = style
        parts = SkimExcerptPart.split(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(parts) { part in
                switch part.content {
                case .prose(let text):
                    style.replyMarkdown(text)
                case .code(let language, let code):
                    SkimCodeBlockView(code: code, language: language, style: style)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The exact original behind a phrase or chip, on a deeper "source" surface:
/// an Original tag, the line range, Copy (each run's exact text), and Show in
/// reply. Runs render with the host's Markdown renderer; gaps say how many
/// blocks were skipped so nothing looks stitched together.
struct SkimExcerptView: View {
    enum Presentation {
        /// Fills a sheet; the body scrolls.
        case sheet
        /// Sizes to its content up to a cap, like a popover should.
        case popover
    }

    let reader: FirstMateSkimReader
    let refs: [String]
    let title: String
    let style: SkimStyle
    var presentation: Presentation = .sheet
    let showInReply: () -> Void
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var contentHeight: CGFloat = 0

    private var runs: [SkimExcerptRun] { reader.runs(for: refs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(style.line)
                .frame(height: 1)
                .accessibilityHidden(true)
            ScrollView {
                excerptBody
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if presentation == .popover { contentHeight = height }
                    }
            }
            .frame(height: presentation == .popover ? min(max(contentHeight, 72), 520) : nil)
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(style.text)
        .background(style.sourceSurface)
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Original text for \(title)")
        .accessibilityIdentifier("skim-excerpt")
    }

    private var excerptBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(runs) { run in
                if let gap = run.gapLabel {
                    gapDivider(gap)
                }
                SkimExcerptRunContent(text: run.text, style: style)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(style.line, in: .capsule)
                    .composerLayoutMeasurement(id: "skim-excerpt-original", label: "Original")
                Text(reader.lineLabel(for: refs))
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
                    .composerLayoutMeasurement(id: "skim-excerpt-lines", label: reader.lineLabel(for: refs))
                Spacer(minLength: 8)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("skim-excerpt-close")
            }
            let actions = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            actions {
                action(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", id: "skim-excerpt-copy") {
                    UIPasteboard.general.string = reader.copyText(for: refs)
                    copied = true
                    hapticPulse.fire(.completed)
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                }
                .accessibilityLabel(copied ? "Original copied" : "Copy original")
                action("Show in reply", symbol: "text.magnifyingglass", id: "skim-excerpt-show-in-reply", perform: showInReply)
                    .accessibilityHint("Opens the full reply at these lines")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.top, presentation == .sheet ? 14 : 4)
        .padding(.bottom, 6)
    }

    private func action(_ title: String, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .foregroundStyle(style.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                // Symbols differ in height; a shared minimum keeps the capsules even.
                .frame(minHeight: 34)
                .background(style.accent.opacity(0.12), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .composerLayoutMeasurement(id: id, label: title)
    }

    private func gapDivider(_ label: String) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(style.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { SkimDashedRule(color: style.line) }
            .overlay(alignment: .bottom) { SkimDashedRule(color: style.line) }
            .composerLayoutMeasurement(id: "skim-excerpt-gap", label: label)
    }
}

/// The full reply split into its segments, so "Show in reply" can tint the
/// referenced blocks and scroll to them. Each segment renders with the host's
/// Markdown renderer, so the reply still reads as it does normally.
struct SkimSegmentedReply: View {
    struct Chunk: Identifiable, Equatable {
        let id: String
        let kind: String
        let text: String
    }

    let messageID: String
    let style: SkimStyle
    let highlighted: Set<String>
    private let chunks: [Chunk]

    init(messageID: String, reader: FirstMateSkimReader, highlighted: Set<String>, style: SkimStyle) {
        self.messageID = messageID
        self.style = style
        self.highlighted = highlighted
        chunks = Self.chunks(reader)
    }

    /// Every segment in order, plus any non-blank text between segments so
    /// nothing in the reply is dropped.
    static func chunks(_ reader: FirstMateSkimReader) -> [Chunk] {
        let units = Array(reader.canonicalText.utf16)
        var result: [Chunk] = []
        var cursor = 0
        func appendGap(upTo end: Int, id: String) {
            guard end > cursor else { return }
            let gap = String(decoding: units[cursor..<end], as: UTF16.self)
            if gap.contains(where: { !$0.isWhitespace }) {
                result.append(Chunk(id: id, kind: "gap", text: gap))
            }
        }
        for segment in reader.segments {
            appendGap(upTo: segment.start, id: "gap-before-\(segment.id)")
            result.append(Chunk(id: segment.id, kind: segment.kind, text: reader.text(of: segment.id)))
            cursor = max(cursor, segment.end)
        }
        appendGap(upTo: units.count, id: "gap-end")
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.element.id) { index, chunk in
                let isHighlighted = highlighted.contains(chunk.id)
                style.replyMarkdown(chunk.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(isHighlighted ? style.accent.opacity(0.16) : .clear, in: .rect(cornerRadius: 6))
                    .padding(.horizontal, -6)
                    .padding(.top, index == 0 ? 0 : max(0, spacing(after: chunks[index - 1], before: chunk) - 8))
                    .id(SkimScrollID.segment(messageID: messageID, segmentID: chunk.id))
                    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spacing(after previous: Chunk, before chunk: Chunk) -> CGFloat {
        previous.kind == "item" && chunk.kind == "item" ? style.itemSpacing : style.blockSpacing
    }
}

/// A one-point dashed rule.
private struct SkimDashedRule: View {
    let color: Color

    var body: some View {
        SkimRuleShape()
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct SkimRuleShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
