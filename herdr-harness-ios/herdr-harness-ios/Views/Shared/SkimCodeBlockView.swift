import SwiftUI
import UIKit

/// One line of highlighted code. Spans are UTF-16 ranges relative to the line.
struct SkimCodeLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let spans: [SkimCodeHighlighter.Span]
    /// `.added` or `.removed` when the whole line is tinted (diffs, test output).
    let tint: SkimCodeHighlighter.Style?
}

/// Splits highlighter spans (UTF-16 ranges over the whole block) into lines,
/// so every line renders on its own row and a line tint spans the row.
enum SkimCodeLayout {
    static func lineCount(_ code: String) -> Int {
        code.isEmpty ? 0 : code.components(separatedBy: "\n").count
    }

    static func lineCountLabel(_ code: String) -> String {
        let count = lineCount(code)
        return "\(count) line\(count == 1 ? "" : "s")"
    }

    static func lines(_ code: String, language: String?) -> [SkimCodeLine] {
        let spans = SkimCodeHighlighter.spans(code, language: language)
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var result: [SkimCodeLine] = []
        var lineStart = 0
        var first = 0
        for (number, line) in code.components(separatedBy: "\n").enumerated() {
            let length = line.utf16.count
            let lineEnd = lineStart + length
            while first < spans.count, spans[first].location + spans[first].length <= lineStart {
                first += 1
            }
            var lineSpans: [SkimCodeHighlighter.Span] = []
            var tint: SkimCodeHighlighter.Style?
            var index = first
            while index < spans.count, spans[index].location < lineEnd {
                let span = spans[index]
                let lower = max(span.location, lineStart)
                let upper = min(span.location + span.length, lineEnd)
                if lower < upper {
                    let wholeLine = span.location == lineStart && span.length == length
                    if wholeLine, span.style == .added || span.style == .removed {
                        tint = span.style
                    } else {
                        lineSpans.append(.init(location: lower - lineStart, length: upper - lower, style: span.style))
                    }
                }
                index += 1
            }
            result.append(SkimCodeLine(id: number, text: line, spans: lineSpans, tint: tint))
            lineStart = lineEnd + 1
        }
        return result
    }

    static func attributed(_ line: SkimCodeLine, style: SkimStyle) -> AttributedString {
        // An empty Text has no height; a space keeps blank lines in the block.
        guard !line.text.isEmpty else { return AttributedString(" ") }
        let units = Array(line.text.utf16)
        func slice(_ range: Range<Int>) -> String {
            String(decoding: units[range], as: UTF16.self)
        }
        var result = AttributedString()
        var cursor = 0
        for span in line.spans where span.location >= cursor && span.location < units.count {
            if span.location > cursor {
                result.append(AttributedString(slice(cursor..<span.location)))
            }
            let end = min(span.location + span.length, units.count)
            var token = AttributedString(slice(span.location..<end))
            if let color = style.tokenColor(span.style) {
                token.swiftUI.foregroundColor = color
            }
            if span.style == .comment {
                token.swiftUI.font = style.codeFont.italic()
            }
            result.append(token)
            cursor = end
        }
        if cursor < units.count {
            result.append(AttributedString(slice(cursor..<units.count)))
        }
        return result
    }
}

/// A fenced block in an excerpt: language, line count, and Copy code (the
/// code without its fences) above a highlighted body that never wraps.
struct SkimCodeBlockView: View {
    let code: String
    let language: String?
    let style: SkimStyle
    private let lines: [SkimCodeLine]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var viewportWidth: CGFloat = 0

    init(code: String, language: String?, style: SkimStyle) {
        self.code = code
        self.language = language
        self.style = style
        lines = SkimCodeLayout.lines(code, language: language)
    }

    private var languageLabel: String { SkimCodeLanguage.label(language, code: code) }
    private var lineCountLabel: String { SkimCodeLayout.lineCountLabel(code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(style.codeLine)
                .frame(height: 1)
                .accessibilityHidden(true)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(SkimCodeLayout.attributed(line, style: style))
                            .font(style.codeFont)
                            .foregroundStyle(style.text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1.5)
                            // At least the visible width, so a tint spans the row.
                            .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
                            .background(style.lineTint(line.tint))
                    }
                }
                .padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(code)
            .composerLayoutMeasurement(id: "skim-code-body")
        }
        .background(style.codeSurface, in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style.codeLine, lineWidth: 1)
                .accessibilityHidden(true)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private var header: some View {
        // One row normally; at accessibility sizes Copy code moves below the label.
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(languageLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
                Text(lineCountLabel)
                    .font(.caption)
                    .foregroundStyle(style.tertiaryText)
            }
            .fixedSize(horizontal: !isLarge, vertical: true)
            .padding(.top, isLarge ? 8 : 0)
            if !isLarge {
                Spacer(minLength: 8)
            }
            Button {
                UIPasteboard.general.string = code
                copied = true
                hapticPulse.fire(.completed)
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? style.success : style.accent)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .accessibilityLabel(copied ? "Code copied" : "Copy code")
            .accessibilityIdentifier("skim-code-copy")
            .composerLayoutMeasurement(id: "skim-code-copy", label: copied ? "Copied" : "Copy code")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .composerLayoutMeasurement(id: "skim-code-header", label: "\(languageLabel), \(lineCountLabel)")
    }
}
