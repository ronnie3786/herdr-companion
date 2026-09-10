import CoreGraphics

/// Anchor beside the selected line nearest the end of the drag, not the first
/// line of a multiline range (which may already be above the viewport).
enum ChatQuoteAnchor {
    static func rect(selectionRects: [CGRect], visibleRect: CGRect, preferredPoint: CGPoint?) -> CGRect? {
        let visible = selectionRects.map { $0.intersection(visibleRect) }.filter { !$0.isNull && !$0.isEmpty }
        guard let last = visible.last else { return nil }
        let point = preferredPoint ?? CGPoint(x: last.maxX, y: last.midY)
        guard let closest = visible.min(by: { distance(point, to: $0) < distance(point, to: $1) }) else { return nil }
        let x = min(max(point.x, closest.minX), closest.maxX)
        // A narrow anchor keeps long selections from centering the popover
        // hundreds of points away from the pointer's selection endpoint.
        let width = min(6, closest.width)
        return CGRect(x: min(max(closest.minX, x - 3), closest.maxX - width), y: closest.minY, width: width, height: closest.height)
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
