import Foundation

/// Presentation preferences for First Mate windows and the Dock badge.
enum FirstMateChatPreferences {
    /// The draggable conversation-list width, shared by every route into the
    /// single standalone chat scene and restored after relaunch.
    static let sidebarWidthKey = "herdr.mac.firstMate.chatWindow.sidebarWidth"
    static let defaultSidebarWidth = 320.0
    /// The inspector's chosen width, restored after closing or relaunching.
    static let inspectorWidthKey = "herdr.mac.firstMate.chatWindow.inspectorWidth"
    static let defaultInspectorWidth = 410.0
    /// Settings ▸ General ▸ "Show First Mate count on the Dock icon".
    static let dockBadgeEnabledKey = "herdr.mac.firstMate.dockBadge"
    static let defaultDockBadgeEnabled = true
}
