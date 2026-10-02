import SwiftUI

/// Chips wrap naturally, including when the user increases Herdr's text size.
struct SkimReplyFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, placement) in layout.items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.minX, y: bounds.minY + placement.minY),
                                  proposal: ProposedViewSize(placement.size))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let limit = max(1, width ?? .greatestFiniteMagnitude)
        var items: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(limit, natural.width), height: nil))
            if x > 0, x + size.width > limit {
                x = 0
                y += height + spacing
                height = 0
            }
            items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            height = max(height, size.height)
        }
        return (CGSize(width: width ?? usedWidth, height: y + height), items)
    }
}
