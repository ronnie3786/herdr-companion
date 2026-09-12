import SwiftUI

/// Shared minimum sizes and indentation for the compact navigator drawer.
/// Text uses Dynamic Type styles at call sites; these values describe only
/// touch targets and hierarchy spacing, never fixed text sizes.
enum SidebarMetrics {
    static let containerHorizontalPadding = 10.0
    static let rowHorizontalPadding = 8.0
    static let rowTrailingPadding = 8.0
    static let workspaceRowLeadingPadding = 6.0
    static let tabRowLeadingPadding = 18.0
    static let chatRowLeadingPadding = 28.0

    static let controlHeight = 44.0
    static let machineRowHeight = 48.0
    static let workspaceRowHeight = 48.0
    static let tabRowHeight = 44.0
    static let chatRowHeight = 44.0
    static let recentRowHeight = 64.0
    static let placeholderRowHeight = 44.0
    static let cornerRadius = 8.0
}
