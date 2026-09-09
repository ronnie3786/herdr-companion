import CoreFoundation
import Testing
@testable import herdr_harness_mac

@Suite("Sidebar metrics")
struct SidebarMetricsTests {
    @Test("Typography and icons use the old-to-enlarged midpoint")
    func typographyMidpoints() {
        #expect(SidebarMetrics.projectLabelSize == 13.5)
        #expect(SidebarMetrics.tabLabelSize == 12.5)
        #expect(SidebarMetrics.chatLabelSize == 13.5)
        #expect(SidebarMetrics.hierarchyIconSize == 11.5)
    }

    @Test("Comfortable rows share a 34-point minimum throughout the hierarchy")
    func comfortableRowHeights() {
        #expect(SidebarMetrics.projectRowHeight == 34)
        #expect(SidebarMetrics.tabRowHeight == 34)
        #expect(SidebarMetrics.chatRowHeight == 34)
    }

    @Test("Navigator indentation uses a strictly increasing hierarchy ladder")
    func navigatorIndentationLadder() {
        #expect(SidebarMetrics.containerLeadingPadding == 4)
        #expect(SidebarMetrics.containerTrailingPadding == 8)
        #expect(SidebarMetrics.rowTrailingPadding == 8)
        #expect(SidebarMetrics.workspaceRowLeadingPadding == 8)
        #expect(SidebarMetrics.tabRowLeadingPadding == 10)
        #expect(SidebarMetrics.chatRowLeadingPadding == 20)
        #expect(SidebarMetrics.workspaceRowLeadingPadding < SidebarMetrics.tabRowLeadingPadding)
        #expect(SidebarMetrics.tabRowLeadingPadding < SidebarMetrics.chatRowLeadingPadding)
    }
}
