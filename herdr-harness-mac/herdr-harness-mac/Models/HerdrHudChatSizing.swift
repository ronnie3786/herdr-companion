import CoreGraphics

/// The visible chat card, excluding the panel's shadow and note/voice surfaces.
enum HerdrHudChatSizing {
    static let minimum = CGSize(width: 420, height: 480)
    static let maximum = CGSize(width: 1200, height: 1200)

    static func constrained(_ proposed: CGSize, screen: CGSize, otherHeight: CGFloat = 0) -> CGSize {
        let width = proposed.width.isFinite && proposed.width > 0 ? proposed.width : HerdrHudPlacement.expandedSize.width
        let height = proposed.height.isFinite && proposed.height > 0 ? proposed.height : HerdrHudPlacement.expandedSize.height
        let margin = HerdrHudPlacement.shadowMargin * 2
        let availableWidth = screen.width > 0 ? max(1, screen.width - margin) : maximum.width
        let availableHeight = screen.height > 0 ? max(1, screen.height - margin - max(0, otherHeight)) : maximum.height
        return CGSize(width: min(max(width, minimum.width), maximum.width, availableWidth),
                      height: min(max(height, minimum.height), maximum.height, availableHeight))
    }
}
