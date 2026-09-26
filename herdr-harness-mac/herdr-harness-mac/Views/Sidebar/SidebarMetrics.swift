import SwiftUI

/// MonoCode's session-sidebar geometry. Every height is a minimum, never a
/// fixed height, so rows grow with the app's text size.
enum SidebarMetrics {
    // Bands and list framing.
    static let headerHeight: CGFloat = HerdrTheme.ControlHeight.titleBar
    static let bandHeight: CGFloat = HerdrTheme.ControlHeight.bar
    static let navRowHeight: CGFloat = HerdrTheme.ControlHeight.row
    static let staleRowHeight: CGFloat = 30
    /// The list's inset from the rail's edges.
    static let containerLeadingPadding: CGFloat = 6
    static let containerTrailingPadding: CGFloat = 6
    static let rowTrailingPadding: CGFloat = 8
    static let workspaceRowLeadingPadding: CGFloat = 8
    static let tabRowLeadingPadding: CGFloat = 10
    /// A session card's inner padding.
    static let chatRowLeadingPadding: CGFloat = 10
    static let cardVerticalPadding: CGFloat = 8
    static let compactCardVerticalPadding: CGFloat = 6
    /// Cards inside a folder group sit 4pt in from the group's edges.
    static let folderCardInset: CGFloat = 4

    // Type. Machine and folder rows share 13pt and step apart by weight.
    static let projectLabelSize: CGFloat = HerdrTheme.TextSize.body
    static let projectLabelWeight: Font.Weight = .medium
    static let workspaceLabelSize: CGFloat = HerdrTheme.TextSize.body
    static let workspaceLabelWeight: Font.Weight = .semibold
    static let tabLabelSize: CGFloat = HerdrTheme.TextSize.caption
    static let chatLabelSize: CGFloat = HerdrTheme.TextSize.body
    static let metaLabelSize: CGFloat = HerdrTheme.TextSize.caption
    static let hierarchyIconSize: CGFloat = 12
    static let workspaceIconSize: CGFloat = 14

    // Minimum row heights.
    static let projectRowHeight: CGFloat = HerdrTheme.ControlHeight.row
    static let workspaceRowHeight: CGFloat = HerdrTheme.ControlHeight.row
    static let tabRowHeight: CGFloat = HerdrTheme.minHitTarget
    static let chatRowHeight: CGFloat = HerdrTheme.minHitTarget
    /// Fixed slot for the quick-star, so a star appearing on hover cannot shove
    /// the status age sideways.
    static let starSlotWidth: CGFloat = 16
}
