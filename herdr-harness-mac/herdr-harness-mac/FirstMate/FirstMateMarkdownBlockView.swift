import SwiftUI

struct FirstMateMarkdownBlockView: View {
    let block: PiMarkdownBlock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.firstMateMarkdownDensity) private var density

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        switch block {
        case .paragraph(_, let text):
            FirstMateMarkdownText(text, role: .body)
                .lineSpacing(density.lineSpacing(.body, scale: fontScale))
        case .heading(_, let level, let text):
            FirstMateMarkdownText(text, role: headingRole(level))
                .padding(.top, density == .compact ? 2 : HerdrProse.headingTopSpacing(level))
                .accessibilityAddTraits(.isHeader)
        case .code(_, let language, let code):
            // MonoCode's `.cb`: a language header over 12/20 code.
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: HerdrTheme.ControlHeight.bar, alignment: .leading)
                    Rectangle().fill(palette.line).frame(height: 1)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                        .foregroundStyle(palette.text)
                        .lineSpacing(HerdrProse.lineSpacing(size: 12, lineHeight: 20, scale: fontScale, monospaced: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.text.opacity(0.06), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line) }
        case .list(_, let items):
            FirstMateMarkdownListView(items: items)
        case .quote(_, let text):
            FirstMateMarkdownText(text, role: .quote, color: palette.secondaryText)
                .lineSpacing(density.lineSpacing(.quote, scale: fontScale))
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    // A neutral bar: color is reserved for status.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.text.opacity(0.20))
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
        case .table(_, let table):
            FirstMateMarkdownTableView(table: table)
        case .thematicBreak:
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
    }

    private func headingRole(_ level: Int) -> HerdrProse.Role {
        switch level {
        case 1: .heading1
        case 2: .heading2
        case 3: .heading3
        case 4: .heading4
        case 5: .heading5
        default: .heading6
        }
    }
}
