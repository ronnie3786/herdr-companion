import Testing
@testable import herdr_harness_ios

@Suite("Pane navigation context")
struct PaneNavigationContextTests {
    @Test("Pushed panes rely on native Back instead of duplicating a navigator button")
    func pushedPaneUsesBack() {
        #expect(!PaneNavigationContext.pushed.showsNavigatorButton)
    }

    @Test("A root pane exposes the app navigator")
    func rootPaneShowsNavigator() {
        #expect(PaneNavigationContext.root.showsNavigatorButton)
    }

    @Test("Split detail replaces the system column toggle with the app navigator")
    func splitDetailUsesOnlyAppNavigator() {
        #expect(PaneNavigationContext.splitDetail.showsNavigatorButton)
        #expect(PaneNavigationContext.splitDetail.removesSystemSidebarToggle)
        #expect(!PaneNavigationContext.pushed.removesSystemSidebarToggle)
        #expect(!PaneNavigationContext.root.removesSystemSidebarToggle)
    }
}
