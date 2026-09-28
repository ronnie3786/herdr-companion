import Foundation

/// Settings for the First Mate chat window preview and the Dock badge.
enum FirstMateChatPreferences {
    /// Settings ▸ General ▸ "First Mate chat window (preview)".
    static let windowEnabledKey = "herdr.mac.firstMate.chatWindow"
    static let defaultWindowEnabled = false
    /// Settings ▸ General ▸ "Show First Mate count on the Dock icon".
    /// Independent of the preview window.
    static let dockBadgeEnabledKey = "herdr.mac.firstMate.dockBadge"
    static let defaultDockBadgeEnabled = true
}
