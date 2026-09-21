import SwiftUI

struct FirstMateMarkdownBlockView: View {
    let block: PiMarkdownBlock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        switch block {
        case .paragraph(_, let text):
            FirstMateMarkdownText(text, role: .body)
                .lineSpacing(HerdrProse.lineSpacing(.body, scale: fontScale))
        case .heading(_, let level, let text):
            FirstMateMarkdownText(text, role: headingRole(level))
                .padding(.top, HerdrProse.headingTopSpacing(level))
                .accessibilityAddTraits(.isHeader)
        case .code(_, let language, let code):
            VStack(alignment: .leading, spacing: 10) {
                if let language, !language.isEmpty {
                    Text(language).herdrFont(.caption).foregroundStyle(palette.secondaryText)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .herdrFont(.body, monospaced: true)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: .rect(cornerRadius: 10))
        case .list(_, let items):
            FirstMateMarkdownListView(items: items)
        case .quote(_, let text):
            FirstMateMarkdownText(text, role: .quote, color: palette.secondaryText)
                .lineSpacing(HerdrProse.lineSpacing(.quote, scale: fontScale))
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.accent.opacity(0.5))
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
        case .table(_, let table):
            FirstMateMarkdownTableView(table: table)
        case .thematicBreak:
            Rectangle()
                .fill(palette.line)
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
