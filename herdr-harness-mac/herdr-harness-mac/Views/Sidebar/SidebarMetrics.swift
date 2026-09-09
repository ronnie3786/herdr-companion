import SwiftUI

enum SidebarMetrics {
    // Indent ladder for the navigator's hierarchy. Kept here so the rows and the
    // section titles that align with them cannot drift apart.
    static let containerLeadingPadding: CGFloat = 8
    static let containerTrailingPadding: CGFloat = 8
    static let rowTrailingPadding: CGFloat = 8
    static let workspaceRowLeadingPadding: CGFloat = 8
    static let tabRowLeadingPadding: CGFloat = 30
    static let chatRowLeadingPadding: CGFloat = 34

    // Quiet chrome keeps persistent navigation smaller than the conversation.
    static let projectLabelSize: CGFloat = 12
    static let tabLabelSize: CGFloat = 12
    static let chatLabelSize: CGFloat = 12
    static let hierarchyIconSize: CGFloat = 12

    // Shared minimum row height across the navigator hierarchy.
    static let projectRowHeight: CGFloat = 30
    static let tabRowHeight: CGFloat = 30
    static let chatRowHeight: CGFloat = 30
    /// Fixed slot for the quick-star, so a star appearing on hover cannot shove
    /// the status age sideways.
    static let starSlotWidth: CGFloat = 16
}
