import Foundation

/// Describes how a pane is owned by its navigation container. Pane chrome must
/// not infer this from global selection or tab-bar visibility: those values do
/// not say whether SwiftUI already supplied Back or split-view column controls.
enum PaneNavigationContext: Equatable {
    /// A destination pushed by a NavigationStack. SwiftUI owns Back and swipe.
    case pushed
    /// A root pane with no system navigation affordance.
    case root
    /// NavigationSplitView detail. The pane replaces SwiftUI's column toggle
    /// with the app's chat navigator action.
    case splitDetail

    var showsNavigatorButton: Bool {
        self != .pushed
    }

    var removesSystemSidebarToggle: Bool {
        self == .splitDetail
    }
}
