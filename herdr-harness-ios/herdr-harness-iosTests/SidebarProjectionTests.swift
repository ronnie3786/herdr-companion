import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Sidebar projection")
struct SidebarProjectionTests {
    private let machines = [
        HerdrMachine(id: "desktop", name: "Desktop", urlString: "https://desktop.example.invalid"),
        HerdrMachine(id: "laptop", name: "Laptop", urlString: "https://laptop.example.invalid"),
    ]

    @Test("Recents is a flat newest twenty ranking")
    func recentsRanksAndLimits() {
        let base = Date(timeIntervalSince1970: 1_735_732_800)
        let panes = (0..<21).map { index in
            pane(
                id: "w1:p\(index)",
                workspaceID: "w1",
                tabID: "w1:t1",
                title: "Chat \(index)",
                lastActivityAt: base.addingTimeInterval(Double(index))
            )
        }
        let workspace = workspace(
            id: "w1",
            number: 1,
            label: "Garden Planner",
            tabs: [tab(id: "w1:t1", workspaceID: "w1", number: 1, label: "Agents", paneCount: 21)],
            panes: panes
        ).stamped(machineID: "desktop")

        let projection = makeProjection(workspaces: [workspace], recency: .recents)

        #expect(projection.isRecents)
        #expect(projection.recentChats.count == 20)
        #expect(projection.recentChats.first?.id == "desktop|w1:p20")
        #expect(!projection.recentChats.contains { $0.id == "desktop|w1:p0" })
        #expect(projection.unreadGroups.isEmpty)
        #expect(projection.tree.isEmpty)
        #expect(projection.visiblePaneCount == 20)
    }

    @Test("Unread wins over Starred and ordinary hierarchy has no duplicates")
    func groupedPriorityIsUnique() {
        let workspace = standardWorkspace.stamped(machineID: "desktop")
        let unreadID = "desktop|w1:p1"
        let starredID = "desktop|w1:p2"
        let projection = makeProjection(
            workspaces: [workspace],
            recency: .all,
            starredPaneIDs: [unreadID, starredID],
            unreadPaneIDs: [unreadID]
        )

        #expect(projection.unreadGroups.flatMap(\.chats).map(\.id) == [unreadID])
        #expect(projection.starredGroups.flatMap(\.chats).map(\.id) == [starredID])
        #expect(projection.tree.flatMap { $0.sections.flatMap(\.chats) }.map(\.id) == ["desktop|w1:p3"])

        let allIDs = projection.unreadGroups.flatMap(\.chats).map(\.id)
            + projection.starredGroups.flatMap(\.chats).map(\.id)
            + projection.tree.flatMap { $0.looseChats + $0.sections.flatMap(\.chats) }.map(\.id)
        #expect(Set(allIDs).count == allIDs.count)
        #expect(projection.visiblePaneCount == 3)
    }

    @Test("Machine, color, and tab-title search filters compose before grouping")
    func filtersCompose() {
        let desktop = standardWorkspace.stamped(machineID: "desktop")
        let laptop = workspace(
            id: "w1",
            number: 1,
            label: "Art Notebook",
            tabs: [tab(id: "w1:t1", workspaceID: "w1", number: 1, label: "Tests", paneCount: 1)],
            panes: [pane(id: "w1:p1", workspaceID: "w1", tabID: "w1:t1", title: "Postcard")]
        ).stamped(machineID: "laptop")

        let projection = makeProjection(
            workspaces: [desktop, laptop],
            machineScope: .machine("desktop"),
            query: "Tests",
            recency: .all,
            colorFilterTabIDs: ["desktop|w1:t2"]
        )

        #expect(projection.visiblePaneCount == 1)
        #expect(projection.tree.map(\.id) == ["desktop|w1"])
        #expect(projection.tree[0].sections.map(\.id) == ["desktop|w1:t2"])
        #expect(projection.tree[0].sections[0].chats.map(\.id) == ["desktop|w1:p3"])
        #expect(projection.machineGroups.map(\.machine.id) == ["desktop"])
    }

    @Test("Color filtering uses scoped tab identity without mutating container counts")
    func colorFilterUsesScopedTabs() {
        let desktop = standardWorkspace.stamped(machineID: "desktop")
        let laptop = standardWorkspace.stamped(machineID: "laptop")

        let filtered = ChatTabColorFilter.workspaces(
            [desktop, laptop],
            tabIDs: ["desktop|w1:t1"]
        )

        #expect(filtered.map(\.id) == ["desktop|w1"])
        #expect(filtered[0].tabs.map(\.id) == ["desktop|w1:t1"])
        #expect(filtered[0].panes.map(\.id) == ["desktop|w1:p1", "desktop|w1:p2"])
        #expect(filtered[0].paneCount == 3)
        #expect(filtered[0].tabs[0].paneCount == 2)
    }

    private var standardWorkspace: HerdrWorkspace {
        workspace(
            id: "w1",
            number: 1,
            label: "Garden Planner",
            tabs: [
                tab(id: "w1:t1", workspaceID: "w1", number: 1, label: "Agents", paneCount: 2),
                tab(id: "w1:t2", workspaceID: "w1", number: 2, label: "Tests", paneCount: 1),
            ],
            panes: [
                pane(id: "w1:p1", workspaceID: "w1", tabID: "w1:t1", title: "Plan herbs"),
                pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", title: "Choose colors"),
                pane(id: "w1:p3", workspaceID: "w1", tabID: "w1:t2", title: "Unit tests"),
            ]
        )
    }

    private func makeProjection(
        workspaces: [HerdrWorkspace],
        machineScope: MachineScope = .all,
        query: String = "",
        recency: SidebarRecency,
        colorFilterTabIDs: Set<String>? = nil,
        starredPaneIDs: Set<String> = [],
        unreadPaneIDs: Set<String> = []
    ) -> SidebarProjection {
        SidebarProjection(
            workspaces: workspaces,
            machines: machines,
            machineStates: ["desktop": .live, "laptop": .live],
            machineScope: machineScope,
            query: query,
            recency: recency,
            colorFilterTabIDs: colorFilterTabIDs,
            collapsedMachineIDs: [],
            collapsedWorkspaceIDs: [],
            collapsedTabIDs: [],
            starredPaneIDs: starredPaneIDs,
            unreadPaneIDs: unreadPaneIDs
        )
    }

    private func workspace(
        id: String,
        number: Int,
        label: String,
        tabs: [HerdrTab],
        panes: [HerdrPane]
    ) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: id,
            number: number,
            label: label,
            focused: false,
            paneCount: panes.count,
            tabCount: tabs.count,
            activeTabID: tabs.first?.id ?? "",
            agentStatus: .idle,
            tabs: tabs,
            panes: panes
        )
    }

    private func tab(
        id: String,
        workspaceID: String,
        number: Int,
        label: String,
        paneCount: Int
    ) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: false,
            paneCount: paneCount,
            agentStatus: .idle
        )
    }

    private func pane(
        id: String,
        workspaceID: String,
        tabID: String,
        title: String,
        lastActivityAt: Date? = nil
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: workspaceID,
            tabID: tabID,
            focused: false,
            agentStatus: .idle,
            revision: 0,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: title,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil,
            lastActivityAt: lastActivityAt
        )
    }
}
