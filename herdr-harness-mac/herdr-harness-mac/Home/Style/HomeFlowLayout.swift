import SwiftUI

/// Inline word/chip flow with a shared baseline. Also used for wrapping action buttons.
struct HomeFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for element in row.elements {
                subviews[element.index].place(at: CGPoint(x: x, y: y + row.baseline - element.baseline),
                                               proposal: ProposedViewSize(element.size))
                x += element.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Element {
        var index: Int
        var size: CGSize
        var baseline: CGFloat
    }

    private struct Row {
        var elements: [Element] = []
        var width: CGFloat = 0
        var baseline: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { baseline + descent }
    }

    private func rows(in availableWidth: CGFloat, subviews: Subviews) -> [Row] {
        let width = max(1, availableWidth)
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let proposal = ProposedViewSize(width: min(width, ideal.width), height: nil)
            let dimensions = subview.dimensions(in: proposal)
            let element = Element(index: index, size: CGSize(width: dimensions.width, height: dimensions.height),
                                  baseline: dimensions[.firstTextBaseline])
            let gap: CGFloat = row.elements.isEmpty ? 0 : spacing
            if !row.elements.isEmpty, row.width + gap + element.size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.elements.isEmpty ? 0 : spacing) + element.size.width
            row.baseline = max(row.baseline, element.baseline)
            row.descent = max(row.descent, element.size.height - element.baseline)
            row.elements.append(element)
        }
        if !row.elements.isEmpty { rows.append(row) }
        return rows
    }
}
