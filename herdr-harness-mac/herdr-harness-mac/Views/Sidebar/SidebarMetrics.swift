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
    // `projectLabelSize` is the quiet 12-point project style shared by machine
    // rows, promoted Unread/Starred group labels, and work-provider headers;
    // workspace folders use `workspaceLabelSize` instead.
    static let projectLabelSize: CGFloat = 12
    static let tabLabelSize: CGFloat = 12
    static let chatLabelSize: CGFloat = 12
    static let hierarchyIconSize: CGFloat = 12

    // Workspace folders are the top rung of the navigator, so their labels and
    // icons step up from the tabs and chats nested beneath them.
    static let workspaceLabelSize: CGFloat = 14
    static let workspaceIconSize: CGFloat = 14

    // Minimum row heights. `projectRowHeight` keeps machine rows, promoted
    // group labels, and work-provider headers compact; workspace folders use
    // the taller `workspaceRowHeight` so titles stay unclipped at every text
    // size. Each value is a minimum, never a fixed height.
    static let projectRowHeight: CGFloat = 30
    static let workspaceRowHeight: CGFloat = 36
    static let tabRowHeight: CGFloat = 30
    static let chatRowHeight: CGFloat = 30
    /// Fixed slot for the quick-star, so a star appearing on hover cannot shove
    /// the status age sideways.
    static let starSlotWidth: CGFloat = 16
}
