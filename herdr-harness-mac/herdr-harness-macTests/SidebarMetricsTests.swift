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

    @Test("Workspace folders step up from the quiet project chrome")
    func workspaceFolderHierarchy() {
        #expect(SidebarMetrics.workspaceLabelSize == 14)
        #expect(SidebarMetrics.workspaceIconSize == 14)
        #expect(SidebarMetrics.workspaceRowHeight == 36)

        // The folder rung must stay larger than the tabs and chats it nests,
        // and larger than the quiet machine/group/header project style that
        // deliberately keeps its 12-point compact values.
        #expect(SidebarMetrics.workspaceLabelSize > SidebarMetrics.projectLabelSize)
        #expect(SidebarMetrics.workspaceLabelSize > SidebarMetrics.tabLabelSize)
        #expect(SidebarMetrics.workspaceLabelSize > SidebarMetrics.chatLabelSize)
        #expect(SidebarMetrics.workspaceIconSize > SidebarMetrics.hierarchyIconSize)
        #expect(SidebarMetrics.workspaceRowHeight > SidebarMetrics.projectRowHeight)
        #expect(SidebarMetrics.workspaceRowHeight > SidebarMetrics.tabRowHeight)
        #expect(SidebarMetrics.workspaceRowHeight > SidebarMetrics.chatRowHeight)
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
