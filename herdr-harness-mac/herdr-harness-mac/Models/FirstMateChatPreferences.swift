import Foundation

/// Settings for the First Mate chat window preview and the Dock badge.
enum FirstMateChatPreferences {
    /// Settings ▸ General ▸ "First Mate chat window (preview)".
    static let windowEnabledKey = "herdr.mac.firstMate.chatWindow"
    static let defaultWindowEnabled = false
    /// The draggable conversation-list width, shared by every route into the
    /// single standalone chat scene and restored after relaunch.
    static let sidebarWidthKey = "herdr.mac.firstMate.chatWindow.sidebarWidth"
    static let defaultSidebarWidth = 320.0
    /// Settings ▸ General ▸ "Show First Mate count on the Dock icon".
    /// Independent of the preview window.
    static let dockBadgeEnabledKey = "herdr.mac.firstMate.dockBadge"
    static let defaultDockBadgeEnabled = true
}
