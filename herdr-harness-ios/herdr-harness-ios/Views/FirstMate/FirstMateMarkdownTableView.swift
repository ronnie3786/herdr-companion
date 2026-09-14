import SwiftUI

struct FirstMateMarkdownTableView: View {
    let table: PiMarkdownTable
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                        Text(PiMarkdownText.render(header))
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 120, idealWidth: 160, maxWidth: 220, alignment: .leading)
                            .padding(12)
                            .background(FirstMatePalette(scheme: scheme).accent.opacity(0.08))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                            Text(PiMarkdownText.render(cell))
                                .font(.subheadline)
                                .frame(minWidth: 120, idealWidth: 160, maxWidth: 220, alignment: .leading)
                                .padding(12)
                                .overlay(alignment: .bottom) { Divider() }
                                .accessibilityLabel("\(table.headers.indices.contains(column) ? table.headers[column] : "Column \(column + 1)"), \(cell)")
                        }
                    }
                }
            }
        }
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(table.headers.count) columns and \(table.rows.count) rows")
    }
}
