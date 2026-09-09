import CoreFoundation
import Testing
@testable import herdr_harness_mac

@Suite("Sidebar metrics")
struct SidebarMetricsTests {
    @Test("Quiet chrome uses compact typography and outline icons")
    func quietChromeTypography() {
        #expect(SidebarMetrics.projectLabelSize == 12)
        #expect(SidebarMetrics.tabLabelSize == 12)
        #expect(SidebarMetrics.chatLabelSize == 12)
        #expect(SidebarMetrics.hierarchyIconSize == 12)
    }

    @Test("Quiet chrome rows share a 30-point minimum throughout the hierarchy")
    func quietChromeRowHeights() {
        #expect(SidebarMetrics.projectRowHeight == 30)
        #expect(SidebarMetrics.tabRowHeight == 30)
        #expect(SidebarMetrics.chatRowHeight == 30)
    }

    @Test("Navigator indentation uses a strictly increasing hierarchy ladder")
    func navigatorIndentationLadder() {
        #expect(SidebarMetrics.containerLeadingPadding == 8)
        #expect(SidebarMetrics.containerTrailingPadding == 8)
        #expect(SidebarMetrics.rowTrailingPadding == 8)
        #expect(SidebarMetrics.workspaceRowLeadingPadding == 8)
        #expect(SidebarMetrics.tabRowLeadingPadding == 30)
        #expect(SidebarMetrics.chatRowLeadingPadding == 34)
        #expect(SidebarMetrics.workspaceRowLeadingPadding < SidebarMetrics.tabRowLeadingPadding)
        #expect(SidebarMetrics.tabRowLeadingPadding < SidebarMetrics.chatRowLeadingPadding)
    }
}
