import SwiftUI

struct FirstMateMarkdownBlockView: View {
    let block: PiMarkdownBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case .paragraph(_, let text):
            Text(PiMarkdownText.render(text)).font(.body).lineSpacing(5)
        case .heading(_, let level, let text):
            Text(PiMarkdownText.render(text))
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .bold()
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .code(_, let language, let code):
            VStack(alignment: .leading, spacing: 10) {
                if let language, !language.isEmpty {
                    Text(language).font(.footnote).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code).font(.subheadline.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 12))
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    FirstMateMarkdownListItemView(item: item)
                }
            }
        case .quote(_, let text):
            Text(PiMarkdownText.render(text))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FirstMatePalette(scheme: scheme).accent.opacity(0.5))
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
        case .table(_, let table):
            FirstMateMarkdownTableView(table: table)
        case .thematicBreak:
            Divider().padding(.vertical, 6)
        }
    }
}
