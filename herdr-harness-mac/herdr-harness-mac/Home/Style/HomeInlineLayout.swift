import SwiftUI

enum HomeInlineKind { case content, space, lineBreak }

struct HomeInlineKindKey: LayoutValueKey {
    static let defaultValue = HomeInlineKind.content
}

/// Adjacent content atoms wrap as a group, keeping punctuation attached to chips.
/// Whitespace supplies measured width rather than an invented word gap.
struct HomeInlineLayout: Layout {
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
                x += element.size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Element {
        var index: Int
        var size: CGSize
        var baseline: CGFloat
        var kind: HomeInlineKind
    }

    private struct Row {
        var elements: [Element] = []
        var width: CGFloat = 0
        var baseline: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { baseline + descent }

        mutating func append(_ element: Element) {
            width += element.size.width
            baseline = max(baseline, element.baseline)
            descent = max(descent, element.size.height - element.baseline)
            elements.append(element)
        }
    }

    private func rows(in availableWidth: CGFloat, subviews: Subviews) -> [Row] {
        let width = max(1, availableWidth)
        let elements = subviews.enumerated().map { index, subview in
            let ideal = subview.sizeThatFits(.unspecified)
            let dimensions = subview.dimensions(in: ProposedViewSize(width: min(width, ideal.width), height: nil))
            return Element(index: index, size: CGSize(width: dimensions.width, height: dimensions.height),
                           baseline: dimensions[.firstTextBaseline], kind: subview[HomeInlineKindKey.self])
        }
        var result: [Row] = []
        var row = Row()
        var pendingSpaces: [Element] = []
        var index = 0
        var afterLineBreak = false
        while index < elements.count {
            let element = elements[index]
            switch element.kind {
            case .space:
                pendingSpaces.append(element)
                index += 1
            case .lineBreak:
                pendingSpaces.forEach { row.append($0) }
                pendingSpaces = []
                row.append(Element(index: element.index, size: CGSize(width: 0, height: element.size.height),
                                   baseline: element.baseline, kind: .lineBreak))
                result.append(row)
                row = Row()
                afterLineBreak = true
                index += 1
            case .content:
                var group: [Element] = []
                while index < elements.count, elements[index].kind == .content {
                    group.append(elements[index]); index += 1
                }
                let required = (pendingSpaces + group).reduce(CGFloat.zero) { $0 + $1.size.width }
                if !row.elements.isEmpty, row.width + required > width {
                    result.append(row)
                    row = Row()
                    pendingSpaces = []
                }
                pendingSpaces.forEach { row.append($0) }
                pendingSpaces = []
                group.forEach { row.append($0) }
                afterLineBreak = false
            }
        }
        pendingSpaces.forEach { row.append($0) }
        if !row.elements.isEmpty { result.append(row) }
        else if afterLineBreak, let last = result.last {
            result.append(Row(baseline: last.baseline, descent: last.descent))
        }
        return result
    }
}
