import AppKit
import SwiftUI

/// The exact original behind a skim phrase, on a deeper "source" surface with
/// an Original tag and its line range. Copy copies the canonical text of each
/// run; Show in reply opens the full reply at those blocks.
struct SkimExcerptView: View {
    let reader: FirstMateSkimReader
    let refs: [String]
    let title: String
    let close: () -> Void
    let showInReply: () -> Void
    @State private var copied = false
    @State private var contentHeight: CGFloat = 160
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.herdrFontScale) private var fontScale

    private static let maximumHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.separator).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reader.runs(for: refs)) { run in
                        if let gap = run.gapLabel {
                            Text(gap)
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(palette.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .overlay(alignment: .top) { dashedRule }
                                .overlay(alignment: .bottom) { dashedRule }
                        }
                        PiMarkdownMessageView(source: run.text, isStreaming: false, detectsPaneLinks: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .environment(\.piCodeBlockStyle, .excerpt)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, Self.maximumHeight * fontScale.rawValue))
        }
        .background(palette.blockFill)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Original text for \(title)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Original")
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                .foregroundStyle(palette.strong)
            Text(reader.lineLabel(for: refs))
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reader.copyText(for: refs), forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            }
            .buttonStyle(SkimMiniButtonStyle())
            .accessibilityIdentifier("skim-excerpt-copy")
            Button("Show in reply", action: showInReply)
                .buttonStyle(SkimMiniButtonStyle())
                .accessibilityIdentifier("skim-excerpt-show-in-reply")
            Button(action: close) {
                Image(systemName: "xmark")
                    .herdrFont(size: 11, weight: .semibold)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .foregroundStyle(palette.secondaryText)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: HerdrTheme.ControlHeight.bar)
    }

    private var dashedRule: some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(palette.separator)
            .frame(height: 1)
    }
}

/// Small bordered text buttons in skim cards and chips.
struct SkimMiniButtonStyle: ButtonStyle {
    @Environment(\.chatProsePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
            .foregroundStyle(configuration.isPressed ? palette.strong : palette.secondaryText)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(configuration.isPressed ? palette.codeFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control).strokeBorder(palette.separator)
            }
            .contentShape(.rect)
    }
}

/// The hover preview: kind, line range, block count, and a snippet. Never
/// interactive; the hint names the click action.
struct SkimPreviewCard: View {
    let preview: SkimPreview
    let hint: String
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(preview.kindWord).fontWeight(.medium).foregroundStyle(palette.strong)
                Text(preview.lineLabel)
                if preview.blockCount > 1 { Text("\(preview.blockCount) blocks") }
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(palette.secondaryText)
            snippet
            Text(hint)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var snippet: some View {
        switch preview.body {
        case .text(let text):
            Text(text)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(palette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .table(let source):
            PiMarkdownMessageView(source: source, isStreaming: false, detectsPaneLinks: false)
                .frame(maxHeight: 150, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        case .code(let code):
            SkimCodePreviewBox(preview: code)
        case .leadIn(let text, let code):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                SkimCodePreviewBox(preview: code)
            }
        }
    }
}

/// Up to eight well-chosen lines of real code: a diff's changed lines or the
/// first lines after imports, faded at the right edge instead of cut.
struct SkimCodePreviewBox: View {
    let preview: SkimCodePreview
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(preview.header)
                .herdrFont(size: HerdrTheme.TextSize.micro + 1)
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            Rectangle().fill(palette.blockOutline).frame(height: 1)
            Text(SkimCodeStyling.highlighted(preview.lines.joined(separator: "\n"), language: preview.languageKey,
                                             palette: palette, scheme: scheme))
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: true)
                // Both bounds, so a long line is clipped instead of widening the card.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            if preview.moreLines > 0 {
                Text("\(preview.moreLines) more line\(preview.moreLines == 1 ? "" : "s") in the popover")
                    .herdrFont(size: HerdrTheme.TextSize.micro + 1)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
        }
        .background(palette.blockFill, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).strokeBorder(palette.blockOutline)
        }
    }
}

/// Maps the shared highlighter's styles onto Mono's syntax palette. The
/// syntax colors are tuned for dark surfaces, so light keeps plain ink.
enum SkimCodeStyling {
    static func highlighted(_ code: String, language: String?, palette: ChatProsePalette, scheme: ColorScheme) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = palette.code
        guard scheme == .dark else { return result }
        let utf16 = code.utf16
        for span in SkimCodeHighlighter.spans(code, language: language) {
            let lower = utf16.index(utf16.startIndex, offsetBy: span.location, limitedBy: utf16.endIndex) ?? utf16.endIndex
            let upper = utf16.index(lower, offsetBy: span.length, limitedBy: utf16.endIndex) ?? utf16.endIndex
            guard let start = AttributedString.Index(lower, within: result),
                  let end = AttributedString.Index(upper, within: result), start < end else { continue }
            switch span.style {
            case .keyword: result[start..<end].foregroundColor = HerdrTheme.Syntax.keyword
            case .string: result[start..<end].foregroundColor = HerdrTheme.Syntax.string
            case .comment: result[start..<end].foregroundColor = palette.secondaryText
            case .number: result[start..<end].foregroundColor = HerdrTheme.working
            case .function: result[start..<end].foregroundColor = HerdrTheme.Syntax.callable
            case .type: result[start..<end].foregroundColor = HerdrTheme.Syntax.type
            case .attribute: result[start..<end].foregroundColor = HerdrTheme.warning
            case .property: result[start..<end].foregroundColor = HerdrTheme.Syntax.property
            case .added: result[start..<end].backgroundColor = HerdrTheme.diffAddRow
            case .removed: result[start..<end].backgroundColor = HerdrTheme.diffRemoveRow
            case .hunk: result[start..<end].foregroundColor = HerdrTheme.diffHunk
            }
        }
        return result
    }
}
