import CoreFoundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Sidebar metrics")
struct SidebarMetricsTests {
    @Test("Session cards use MonoCode's sidebar type ramp")
    func cardTypography() {
        #expect(SidebarMetrics.chatLabelSize == 13)
        #expect(SidebarMetrics.metaLabelSize == 11)
        #expect(SidebarMetrics.tabLabelSize == 11)
        #expect(SidebarMetrics.hierarchyIconSize == 12)
    }

    @Test("Machine and folder rows share 13pt and step apart by weight")
    func workspaceFolderHierarchy() {
        #expect(SidebarMetrics.workspaceLabelSize == 13)
        #expect(SidebarMetrics.projectLabelSize == 13)
        #expect(SidebarMetrics.workspaceLabelWeight == .semibold)
        #expect(SidebarMetrics.projectLabelWeight == .medium)
        #expect(SidebarMetrics.workspaceIconSize == 14)
        #expect(SidebarMetrics.workspaceIconSize > SidebarMetrics.hierarchyIconSize)
        #expect(SidebarMetrics.workspaceLabelSize > SidebarMetrics.tabLabelSize)
    }

    @Test("Bands and rows follow the 40 / 36 / 32 ladder and never drop below the hit floor")
    func rowHeights() {
        #expect(SidebarMetrics.headerHeight == 40)
        #expect(SidebarMetrics.bandHeight == 36)
        #expect(SidebarMetrics.navRowHeight == 32)
        #expect(SidebarMetrics.projectRowHeight == 32)
        #expect(SidebarMetrics.workspaceRowHeight == 32)
        #expect(SidebarMetrics.tabRowHeight >= HerdrTheme.minHitTarget)
        #expect(SidebarMetrics.chatRowHeight >= HerdrTheme.minHitTarget)
        #expect(SidebarMetrics.staleRowHeight >= HerdrTheme.minHitTarget)
    }

    @Test("The list and cards use MonoCode's insets")
    func navigatorInsets() {
        #expect(SidebarMetrics.containerLeadingPadding == 6)
        #expect(SidebarMetrics.containerTrailingPadding == 6)
        #expect(SidebarMetrics.chatRowLeadingPadding == 10)
        #expect(SidebarMetrics.cardVerticalPadding == 8)
        #expect(SidebarMetrics.compactCardVerticalPadding == 6)
        #expect(SidebarMetrics.folderCardInset == 4)
        #expect(SidebarMetrics.workspaceRowLeadingPadding <= SidebarMetrics.tabRowLeadingPadding)
    }
}
