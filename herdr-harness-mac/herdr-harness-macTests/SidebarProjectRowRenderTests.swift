import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Synthetic workspace folders for the sidebar render suite. Every name, tab,
/// chat, and count is invented for the test and never lifted from a real
/// project, machine, or session.
@MainActor
private struct SidebarFolderRenderFixture {
    let ordinary: HerdrWorkspace
    let working: HerdrWorkspace
    let attention: HerdrWorkspace
    let longName: HerdrWorkspace
    let tab: HerdrTab
    let chat: HerdrPane

    init() {
        let tab = HerdrTab(
            tabID: "folders:t1",
            workspaceID: "folders",
            number: 1,
            label: "Sample tab",
            focused: false,
            paneCount: 3,
            agentStatus: .idle
        )
        self.tab = tab
        self.chat = Self.pane(
            id: "folders:p1",
            tabID: tab.tabID,
            title: "Sample chat",
            status: .idle
        )
        self.ordinary = Self.workspace(
            id: "ordinary",
            label: "Sample Project",
            panes: [
                Self.pane(id: "ordinary:p1", tabID: tab.tabID, title: "First", status: .idle),
                Self.pane(id: "ordinary:p2", tabID: tab.tabID, title: "Second", status: .idle),
                Self.pane(id: "ordinary:p3", tabID: tab.tabID, title: "Third", status: .idle),
            ]
        )
        self.working = Self.workspace(
            id: "working",
            label: "Sample Working Project",
            panes: [
                Self.pane(id: "working:p1", tabID: tab.tabID, title: "Building", status: .working),
                Self.pane(id: "working:p2", tabID: tab.tabID, title: "Testing", status: .working),
                Self.pane(id: "working:p3", tabID: tab.tabID, title: "Idle", status: .idle),
            ]
        )
        self.attention = Self.workspace(
            id: "attention",
            label: "Sample Attention Project",
            panes: [
                Self.pane(id: "attention:p1", tabID: tab.tabID, title: "Blocked", status: .blocked),
                Self.pane(id: "attention:p2", tabID: tab.tabID, title: "Idle", status: .idle),
            ]
        )
        self.longName = Self.workspace(
            id: "long-name",
            label: "Aurora Garden Planner with an intentionally long synthetic workspace name",
            panes: [
                Self.pane(id: "long-name:p1", tabID: tab.tabID, title: "First", status: .idle),
                Self.pane(id: "long-name:p2", tabID: tab.tabID, title: "Second", status: .idle),
                Self.pane(id: "long-name:p3", tabID: tab.tabID, title: "Third", status: .idle),
                Self.pane(id: "long-name:p4", tabID: tab.tabID, title: "Fourth", status: .idle),
            ]
        )
    }

    /// Collapsed ordinary/working/attention folders above an expanded folder
    /// whose tab and chat show the hierarchy the larger title should outrank.
    @ViewBuilder
    func hierarchy(width: CGFloat, scale: HerdrFontScale) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarProjectRow(workspace: ordinary, isExpanded: false, action: {})
            SidebarProjectRow(workspace: working, isExpanded: false, action: {})
            SidebarProjectRow(workspace: attention, isExpanded: false, action: {})
            SidebarProjectRow(workspace: longName, isExpanded: true, action: {})
            SidebarSectionRow(tab: tab, isExpanded: true, action: {})
            SidebarChatRow(pane: chat, isSelected: false, action: {})
        }
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .background(HerdrTheme.ink)
        .environment(\.herdrFontScale, scale)
    }

    private static func workspace(id: String, label: String, panes: [HerdrPane]) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: id,
            number: 1,
            label: label,
            focused: false,
            paneCount: panes.count,
            tabCount: 1,
            activeTabID: "folders:t1",
            agentStatus: .idle,
            tabs: [],
            panes: panes
        )
    }

    private static func pane(id: String, tabID: String, title: String, status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "folders",
            tabID: tabID,
            focused: false,
            agentStatus: status,
            revision: 0,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: title,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }
}

@Suite("Sidebar workspace folder rendering", .serialized)
@MainActor
struct SidebarProjectRowRenderTests {
    @Test(
        "Synthetic folder rows render titles and trailing counts at narrow widths",
        arguments: [CGFloat(240), 280],
        [HerdrFontScale.medium, .xxxLarge]
    )
    func rendersWorkspaceFolders(width: CGFloat, scale: HerdrFontScale) async throws {
        let fixture = SidebarFolderRenderFixture()
        let image = try await HerdrRenderHarness.render(
            "sidebar-workspace-folders-\(Int(width))-\(Int(scale.rawValue * 100)).png",
            size: CGSize(width: width, height: 260)
        ) {
            fixture.hierarchy(width: width, scale: scale)
        }

        // The layout assertions below are the proof of bounded, unclipped rows;
        // the PNG is the artifact a person reviews. Byte size alone is never
        // treated as evidence of legibility, so also require ink where the
        // icons, titles, and trailing counts should be.
        image.expectSubstantial()

        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: image.url)))
        let whole = luminance(in: bitmap, columns: 0..<bitmap.pixelsWide, rows: 0..<bitmap.pixelsHigh)
        let leading = luminance(
            in: bitmap,
            columns: 0..<bitmap.pixelsWide / 3,
            rows: 0..<bitmap.pixelsHigh
        )
        let trailing = luminance(
            in: bitmap,
            columns: bitmap.pixelsWide * 2 / 3..<bitmap.pixelsWide,
            rows: 0..<bitmap.pixelsHigh
        )

        #expect(whole.mean < 110, "The dark sidebar chrome should stay dark, was \(whole.mean)")
        #expect(whole.maximum > 150, "No bright title or icon pixels drew, maximum was \(whole.maximum)")
        #expect(leading.maximum > 150, "No disclosure, folder icon, or title pixels drew on the leading edge")
        #expect(trailing.maximum > 120, "No trailing count pixels drew on the trailing edge")
    }

    @Test(
        "Folder rows honor their minimum height and stay inside the sidebar width",
        arguments: [CGFloat(240), 280],
        [HerdrFontScale.medium, .xxxLarge]
    )
    func keepsFolderRowsBounded(width: CGFloat, scale: HerdrFontScale) {
        let fixture = SidebarFolderRenderFixture()

        let titleHeight = fittedHeight(
            of: Text(fixture.longName.label)
                .herdrFont(
                    size: SidebarMetrics.workspaceLabelSize,
                    weight: .semibold,
                    relativeTo: .subheadline
                )
                .environment(\.herdrFontScale, scale)
                .fixedSize()
        )

        // Unconstrained, the long synthetic name wants more room than the
        // sidebar offers, which is what makes the bounded check meaningful.
        let unbounded = NSHostingView(
            rootView: SidebarProjectRow(workspace: fixture.longName, isExpanded: false, action: {})
                .environment(\.herdrFontScale, scale)
        )
        unbounded.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
        unbounded.layoutSubtreeIfNeeded()
        #expect(
            unbounded.fittingSize.width > width,
            "The long fixture name should overflow \(width) points, was \(unbounded.fittingSize.width)"
        )

        let bounded = NSHostingView(
            rootView: SidebarProjectRow(workspace: fixture.longName, isExpanded: true, action: {})
                .environment(\.herdrFontScale, scale)
                .frame(width: width)
        )
        bounded.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        bounded.layoutSubtreeIfNeeded()

        #expect(bounded.fittingSize.width <= width + 0.5)
        #expect(bounded.fittingSize.height >= SidebarMetrics.workspaceRowHeight)
        #expect(bounded.fittingSize.height >= titleHeight)
    }

    @Test("Workspace folder titles grow with the app text-size preference")
    func workspaceTitleFollowsFontPreference() {
        let fixture = SidebarFolderRenderFixture()
        let medium = fittedHeight(of: titleText(fixture.longName.label, scale: .medium))
        let xxxLarge = fittedHeight(of: titleText(fixture.longName.label, scale: .xxxLarge))

        #expect(xxxLarge > medium)
    }

    @Test("Workspace folder titles and icons use the stronger theme colors")
    func workspaceFolderColorsStepUp() {
        let fixture = SidebarFolderRenderFixture()
        let row = SidebarProjectRow(workspace: fixture.ordinary, isExpanded: false, action: {})

        #expect(row.titleColor == HerdrTheme.text)
        #expect(row.folderIconColor == HerdrTheme.mist)
    }

    private func titleText(_ label: String, scale: HerdrFontScale) -> some View {
        Text(label)
            .herdrFont(
                size: SidebarMetrics.workspaceLabelSize,
                weight: .semibold,
                relativeTo: .subheadline
            )
            .environment(\.herdrFontScale, scale)
            .fixedSize()
    }

    private func fittedHeight(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func luminance(
        in bitmap: NSBitmapImageRep,
        columns: Range<Int>,
        rows: Range<Int>
    ) -> (mean: Double, maximum: Double) {
        var total = 0.0
        var maximum = 0.0
        var sampleCount = 0

        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let value = (0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent) * 255
                total += value
                maximum = max(maximum, value)
                sampleCount += 1
            }
        }

        return (total / Double(max(sampleCount, 1)), maximum)
    }
}
