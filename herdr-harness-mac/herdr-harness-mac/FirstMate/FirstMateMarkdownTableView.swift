import SwiftUI

struct FirstMateMarkdownTableView: View {
    let table: PiMarkdownTable
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                        FirstMateMarkdownText(header, role: .tableHeader)
                            .frame(minWidth: 120, idealWidth: 160, maxWidth: 220, alignment: .leading)
                            .padding(12)
                            .background(palette.accent.opacity(0.08))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                            FirstMateMarkdownText(cell, role: .tableCell)
                                .frame(minWidth: 120, idealWidth: 160, maxWidth: 220, alignment: .leading)
                                .padding(12)
                                .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                                .accessibilityLabel("\(table.headers.indices.contains(column) ? table.headers[column] : "Column \(column + 1)"), \(cell)")
                        }
                    }
                }
            }
        }
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(table.headers.count) columns and \(table.rows.count) rows")
    }
}
