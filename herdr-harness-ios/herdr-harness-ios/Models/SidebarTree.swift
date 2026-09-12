import Foundation

enum SidebarTree {
    struct ProjectEntry: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let isExpanded: Bool
        let sections: [SectionEntry]
        let looseChats: [HerdrPane]

        var id: String { workspace.id }
    }

    struct SectionEntry: Identifiable, Equatable {
        let tab: HerdrTab
        let isExpanded: Bool
        let chats: [HerdrPane]

        var id: String { tab.id }
    }

    struct StarredGroup: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let chats: [HerdrPane]

        var id: String { "starred:\(workspace.id)" }
    }

    struct UnreadGroup: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let chats: [HerdrPane]

        var id: String { "unread:\(workspace.id)" }
    }

    struct MachineGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        let state: ConnectionState
        let isExpanded: Bool
        let entries: [ProjectEntry]

        var id: String { "machine:\(machine.id)" }
    }

    /// Human-readable workspace order with a deterministic creation-order tie.
    static func byWorkspaceName(_ lhs: HerdrWorkspace, _ rhs: HerdrWorkspace) -> Bool {
        let comparison = lhs.label.localizedStandardCompare(rhs.label)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.number < rhs.number
    }

    static func build(
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String> = [],
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.sorted(by: byWorkspaceName).compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                collapsedTabIDs: collapsedTabIDs,
                excludedPaneIDs: starredIDs.union(excludedPaneIDs),
                recency: recency,
                now: now,
                calendar: calendar
            )
        }
    }

    static func starredGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        starredIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [StarredGroup] {
        priorityGroups(
            workspaces: workspaces,
            query: query,
            includedPaneIDs: starredIDs,
            excludedPaneIDs: excludedPaneIDs,
            machines: machines,
            recency: recency,
            now: now,
            calendar: calendar
        ).map { StarredGroup(workspace: $0.workspace, chats: $0.chats) }
    }

    static func unreadGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        unreadIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recency: SidebarRecency = .all,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UnreadGroup] {
        priorityGroups(
            workspaces: workspaces,
            query: query,
            includedPaneIDs: unreadIDs,
            excludedPaneIDs: [],
            machines: machines,
            recency: recency,
            now: now,
            calendar: calendar
        ).map { UnreadGroup(workspace: $0.workspace, chats: $0.chats) }
    }

    static func machineGroups(
        machines: [HerdrMachine],
        states: [String: ConnectionState],
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedMachineIDs: Set<String>,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String> = [],
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MachineGroup] {
        let entries = build(
            workspaces: workspaces,
            query: query,
            collapsedWorkspaceIDs: collapsedWorkspaceIDs,
            collapsedTabIDs: collapsedTabIDs,
            starredIDs: starredIDs,
            recency: recency,
            excludedPaneIDs: excludedPaneIDs,
            now: now,
            calendar: calendar
        )
        return machineGroups(
            machines: machines,
            states: states,
            entries: entries,
            query: query,
            collapsedMachineIDs: collapsedMachineIDs
        )
    }

    static func machineGroups(
        machines: [HerdrMachine],
        states: [String: ConnectionState],
        entries: [ProjectEntry],
        query: String,
        collapsedMachineIDs: Set<String>
    ) -> [MachineGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.map { machine in
            MachineGroup(
                machine: machine,
                state: states[machine.id] ?? .disconnected,
                isExpanded: trimmedQuery.isEmpty ? !collapsedMachineIDs.contains(machine.id) : true,
                entries: entries.filter { $0.workspace.machineID == machine.id }
            )
        }
    }

    /// Flat newest-first conversations. Container hierarchy is intentionally
    /// absent because it would erase the ranking this mode exists to show.
    static func recentChats(
        workspaces: [HerdrWorkspace],
        query: String,
        limit: Int = SidebarRecency.recentsLimit
    ) -> [HerdrPane] {
        guard limit > 0 else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(workspaces.flatMap { workspace in
            let workspaceMatches = matchesWorkspace(workspace, query: trimmedQuery)
            let matchingTabIDs = matchingTabIDs(in: workspace, query: trimmedQuery)
            return workspace.panes.filter { pane in
                workspaceMatches
                    || matchingTabIDs.contains(pane.scopedTabID)
                    || matchesPaneQuery(pane, query: trimmedQuery)
            }
        }
        .sorted {
            let lhsActivity = $0.lastActivityAt ?? $0.firstSeenAt ?? .distantPast
            let rhsActivity = $1.lastActivityAt ?? $1.firstSeenAt ?? .distantPast
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            return $0.id < $1.id
        }
        .prefix(limit))
    }

    private struct PriorityGroup {
        let workspace: HerdrWorkspace
        let chats: [HerdrPane]
    }

    private static func priorityGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        includedPaneIDs: Set<String>,
        excludedPaneIDs: Set<String>,
        machines: [HerdrMachine],
        recency: SidebarRecency,
        now: Date,
        calendar: Calendar
    ) -> [PriorityGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineOrder = Dictionary(
            uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) }
        )
        return workspaces
            .sorted { lhs, rhs in
                let lhsOrder = machineOrder[lhs.machineID] ?? Int.max
                let rhsOrder = machineOrder[rhs.machineID] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return byWorkspaceName(lhs, rhs)
            }
            .compactMap { workspace in
                let workspaceMatches = matchesWorkspace(workspace, query: trimmedQuery)
                let matchingTabs = matchingTabIDs(in: workspace, query: trimmedQuery)
                let chats = workspace.panes
                    .filter { pane in
                        includedPaneIDs.contains(pane.id)
                            && !excludedPaneIDs.contains(pane.id)
                            && recency.includes(pane, now: now, calendar: calendar)
                            && (workspaceMatches
                                || matchingTabs.contains(pane.scopedTabID)
                                || matchesPaneQuery(pane, query: trimmedQuery))
                    }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return PriorityGroup(workspace: workspace, chats: chats)
            }
    }

    private static func buildEntry(
        for workspace: HerdrWorkspace,
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String>,
        excludedPaneIDs: Set<String>,
        recency: SidebarRecency,
        now: Date,
        calendar: Calendar
    ) -> ProjectEntry? {
        let sortedTabs = workspace.tabs.sorted { $0.number < $1.number }
        let tabIDs = Set(sortedTabs.map(\.id))
        let workspaceMatches = matchesWorkspace(workspace, query: query)
        let matchingTabs = matchingTabIDs(in: workspace, query: query)
        let matchingPanes = Set(workspace.panes.filter {
            matchesPaneQuery($0, query: query)
                && !excludedPaneIDs.contains($0.id)
                && recency.includes($0, now: now, calendar: calendar)
        }.map(\.id))

        guard query.isEmpty || workspaceMatches || !matchingTabs.isEmpty || !matchingPanes.isEmpty else {
            return nil
        }

        let filteredPanes = workspace.panes.filter { pane in
            !excludedPaneIDs.contains(pane.id)
                && recency.includes(pane, now: now, calendar: calendar)
                && (query.isEmpty
                    || workspaceMatches
                    || matchingPanes.contains(pane.id)
                    || matchingTabs.contains(pane.scopedTabID))
        }
        let filtersPanes = recency != .all || !excludedPaneIDs.isEmpty

        let sections = sortedTabs.compactMap { tab -> SectionEntry? in
            let chats = filteredPanes
                .filter { $0.scopedTabID == tab.id }
                .sorted { $0.paneID < $1.paneID }
            let preservesEmptyTab = query.isEmpty && !filtersPanes
            let matchedEmptyTab = !filtersPanes && matchingTabs.contains(tab.id)
            guard preservesEmptyTab || !chats.isEmpty || matchedEmptyTab else { return nil }
            return SectionEntry(
                tab: tab,
                isExpanded: query.isEmpty ? !collapsedTabIDs.contains(tab.id) : true,
                chats: chats
            )
        }
        let looseChats = filteredPanes
            .filter { !tabIDs.contains($0.scopedTabID) }
            .sorted { $0.paneID < $1.paneID }

        guard !filtersPanes || !sections.isEmpty || !looseChats.isEmpty else { return nil }
        return ProjectEntry(
            workspace: workspace,
            isExpanded: query.isEmpty ? !collapsedWorkspaceIDs.contains(workspace.id) : true,
            sections: sections,
            looseChats: looseChats
        )
    }

    private static func matchesWorkspace(_ workspace: HerdrWorkspace, query: String) -> Bool {
        query.isEmpty
            || workspace.label.localizedStandardContains(query)
            || workspace.displayPath.localizedStandardContains(query)
    }

    private static func matchingTabIDs(in workspace: HerdrWorkspace, query: String) -> Set<String> {
        guard !query.isEmpty else { return [] }
        return Set(workspace.tabs.filter {
            $0.label.localizedStandardContains(query)
        }.map(\.id))
    }

    private static func matchesPaneQuery(_ pane: HerdrPane, query: String) -> Bool {
        query.isEmpty || pane.displayTitle.localizedStandardContains(query)
    }
}
