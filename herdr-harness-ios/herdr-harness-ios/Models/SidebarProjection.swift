import Foundation

/// One deterministic navigator projection after scope, color, query, range, and
/// priority rules have been applied in that order.
struct SidebarProjection: Equatable {
    let isRecents: Bool
    let recentChats: [HerdrPane]
    let unreadGroups: [SidebarTree.UnreadGroup]
    let starredGroups: [SidebarTree.StarredGroup]
    let tree: [SidebarTree.ProjectEntry]
    let machineGroups: [SidebarTree.MachineGroup]
    let visiblePaneCount: Int

    init(
        workspaces: [HerdrWorkspace],
        machines: [HerdrMachine],
        machineStates: [String: ConnectionState],
        machineScope: MachineScope,
        query: String,
        recency: SidebarRecency,
        colorFilterTabIDs: Set<String>?,
        collapsedMachineIDs: Set<String>,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String>,
        starredPaneIDs: Set<String>,
        unreadPaneIDs: Set<String>,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let scopedWorkspaces: [HerdrWorkspace]
        let scopedMachines: [HerdrMachine]
        switch machineScope {
        case .all:
            scopedWorkspaces = workspaces
            scopedMachines = machines
        case let .machine(machineID):
            scopedWorkspaces = workspaces.filter { $0.machineID == machineID }
            scopedMachines = machines.filter { $0.id == machineID }
        }

        let colorFiltered = ChatTabColorFilter.workspaces(
            scopedWorkspaces,
            tabIDs: colorFilterTabIDs
        )

        isRecents = recency == .recents
        if isRecents {
            let chats = SidebarTree.recentChats(
                workspaces: colorFiltered,
                query: query
            )
            recentChats = chats
            unreadGroups = []
            starredGroups = []
            tree = []
            machineGroups = []
            visiblePaneCount = Set(chats.map(\.id)).count
            return
        }

        recentChats = []
        let unread = SidebarTree.unreadGroups(
            workspaces: colorFiltered,
            query: query,
            unreadIDs: unreadPaneIDs,
            machines: scopedMachines,
            recency: recency,
            now: now,
            calendar: calendar
        )
        let starred = SidebarTree.starredGroups(
            workspaces: colorFiltered,
            query: query,
            starredIDs: starredPaneIDs,
            machines: scopedMachines,
            recency: recency,
            excludedPaneIDs: unreadPaneIDs,
            now: now,
            calendar: calendar
        )
        let ordinary = SidebarTree.build(
            workspaces: colorFiltered,
            query: query,
            collapsedWorkspaceIDs: collapsedWorkspaceIDs,
            collapsedTabIDs: collapsedTabIDs,
            starredIDs: starredPaneIDs,
            recency: recency,
            excludedPaneIDs: unreadPaneIDs,
            now: now,
            calendar: calendar
        )

        unreadGroups = unread
        starredGroups = starred
        tree = ordinary
        machineGroups = SidebarTree.machineGroups(
            machines: scopedMachines,
            states: machineStates,
            entries: ordinary,
            query: query,
            collapsedMachineIDs: collapsedMachineIDs
        )

        let priorityPaneIDs = unread.flatMap(\.chats).map(\.id)
            + starred.flatMap(\.chats).map(\.id)
        let ordinaryPaneIDs = ordinary.flatMap { entry in
            entry.looseChats.map(\.id) + entry.sections.flatMap(\.chats).map(\.id)
        }
        visiblePaneCount = Set(priorityPaneIDs + ordinaryPaneIDs).count
    }
}
