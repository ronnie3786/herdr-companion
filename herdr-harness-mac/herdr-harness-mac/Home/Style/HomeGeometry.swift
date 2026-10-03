import Foundation

/// Logical point measurements from the locked Home reference.
enum HomeGeometry {
    static let topInset: CGFloat = 92
    static let bottomInset: CGFloat = 116
    static let avatar: CGFloat = 168
    static let contentMaximum: CGFloat = 780
    static let chatMinimum: CGFloat = 290

    struct Grid: Equatable {
        var column: CGFloat
        var gap: CGFloat
        var padding: CGFloat
        var content: CGFloat
        var width: CGFloat { column + gap + content }
    }

    static func grid(width: CGFloat) -> Grid {
        let narrow = width <= 1360
        let column: CGFloat = narrow ? 250 : 290
        let gap: CGFloat = narrow ? 32 : 44
        let padding: CGFloat = narrow ? 28 : 40
        return Grid(column: column, gap: gap, padding: padding,
                    content: min(contentMaximum, max(1, width - padding * 2 - column - gap)))
    }
}
