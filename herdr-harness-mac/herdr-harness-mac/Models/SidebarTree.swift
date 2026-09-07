import Foundation

enum SidebarTree {
    struct ProjectEntry: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let isExpanded: Bool
        let sections: [SectionEntry]
        let looseChats: [HerdrPane]
        var looseRows: [PiSessionTree.Row] = []

        var id: String { workspace.id }
    }

    struct SectionEntry: Identifiable, Equatable {
        let tab: HerdrTab
        let isExpanded: Bool
        let chats: [HerdrPane]
        var rows: [PiSessionTree.Row] = []

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

    struct StaleGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        let chats: [HerdrPane]

        var id: String { "stale:\(machine.id)" }
        var workspaceIDs: [String] { Array(Set(chats.map(\.workspaceID))).sorted() }
    }

    /// Workspaces read alphabetically rather than in creation order.
    ///
    /// `number` is the order terminal happened to open them in, which is stable but
    /// meaningless to a reader scanning for a project by name. Ties fall back to
    /// `number` so the order stays deterministic when two workspaces share a
    /// label, and comparison is `localizedStandardCompare` so "Herdr 10" sorts
    /// after "Herdr 9" instead of before it.
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
        collapsedSessionIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = workspaces.sorted(by: Self.byWorkspaceName).compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                collapsedTabIDs: collapsedTabIDs,
                starredIDs: starredIDs,
                recency: recency,
                excludedPaneIDs: excludedPaneIDs,
                now: now,
                calendar: calendar
            )
        }
        return attachingSessionFamilies(
            entries: entries, workspaces: workspaces, query: trimmedQuery,
            excludedIDs: starredIDs.union(excludedPaneIDs),
            collapsedWorkspaceIDs: collapsedWorkspaceIDs,
            collapsedTabIDs: collapsedTabIDs,
            collapsedSessionIDs: trimmedQuery.isEmpty ? collapsedSessionIDs : []
        )
    }

    private static func attachingSessionFamilies(
        entries: [ProjectEntry], workspaces: [HerdrWorkspace], query: String,
        excludedIDs: Set<String>, collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String>, collapsedSessionIDs: Set<String>
    ) -> [ProjectEntry] {
        let sessions = PiSessionTree(workspaces: workspaces)
        let visibleIDs = Set(entries.flatMap { $0.looseChats + $0.sections.flatMap(\.chats) }.map(\.id))
        let includedIDs = sessions.includingAncestors(of: visibleIDs, excluding: excludedIDs)
        let roots = sessions.roots(in: includedIDs)
        let originalEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return workspaces.sorted(by: byWorkspaceName).compactMap { workspace in
            let original = originalEntries[workspace.id]
            let workspaceRoots = roots.filter { $0.machineID == workspace.machineID && $0.workspaceID == workspace.workspaceID }
            guard original != nil || !workspaceRoots.isEmpty else { return nil }
            let tabIDs = Set(workspace.tabs.map(\.id))
            let sections = workspace.tabs.sorted { $0.number < $1.number }.compactMap { tab -> SectionEntry? in
                let tabRoots = workspaceRoots.filter { $0.scopedTabID == tab.id }
                let originalSection = original?.sections.first { $0.id == tab.id }
                // Preserve truly empty terminal tabs, but do not leave a blank
                // copy where every chat has moved beneath its session parent.
                guard !tabRoots.isEmpty || originalSection?.chats.isEmpty == true else { return nil }
                let allRows = sessions.rows(roots: tabRoots, includedIDs: includedIDs, collapsedSessionIDs: [])
                return SectionEntry(
                    tab: tab, isExpanded: query.isEmpty ? !collapsedTabIDs.contains(tab.id) : true,
                    chats: allRows.map(\.pane),
                    rows: sessions.rows(roots: tabRoots, includedIDs: includedIDs, collapsedSessionIDs: collapsedSessionIDs)
                )
            }
            let looseRoots = workspaceRoots.filter { !tabIDs.contains($0.scopedTabID) }
            let allLooseRows = sessions.rows(roots: looseRoots, includedIDs: includedIDs, collapsedSessionIDs: [])
            let hadChats = original.map { !$0.looseChats.isEmpty || $0.sections.contains { !$0.chats.isEmpty } } ?? false
            guard !sections.isEmpty || !looseRoots.isEmpty || !hadChats else { return nil }
            return ProjectEntry(
                workspace: workspace,
                isExpanded: query.isEmpty ? !collapsedWorkspaceIDs.contains(workspace.id) : true,
                sections: sections, looseChats: allLooseRows.map(\.pane),
                looseRows: sessions.rows(roots: looseRoots, includedIDs: includedIDs, collapsedSessionIDs: collapsedSessionIDs)
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
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [StarredGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineOrder = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) })
        return workspaces
            .sorted {
                let lhsMachine = MachineScopedID.split($0.id)?.machineID
                let rhsMachine = MachineScopedID.split($1.id)?.machineID
                let lhsOrder = lhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                let rhsOrder = rhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return byWorkspaceName($0, $1)
            }
            .compactMap { workspace in
                let chats = workspace.panes
                    .filter {
                        starredIDs.contains($0.id)
                            && !excludedPaneIDs.contains($0.id)
                            && matchesPaneQuery($0, query: trimmedQuery)
                            && recency.includes($0, now: now, calendar: calendar)
                    }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return StarredGroup(workspace: workspace, chats: chats)
            }
    }

    static func unreadGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        unreadIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recency: SidebarRecency = .all,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UnreadGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineOrder = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) })
        return workspaces
            .sorted {
                let lhsMachine = MachineScopedID.split($0.id)?.machineID
                let rhsMachine = MachineScopedID.split($1.id)?.machineID
                let lhsOrder = lhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                let rhsOrder = rhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return byWorkspaceName($0, $1)
            }
            .compactMap { workspace in
                let workspaceMatches = trimmedQuery.isEmpty
                    || workspace.label.localizedStandardContains(trimmedQuery)
                    || workspace.displayPath.localizedStandardContains(trimmedQuery)
                let matchingTabIDs = Set(workspace.tabs.filter {
                    $0.label.localizedStandardContains(trimmedQuery)
                }.map(\.id))
                let chats = workspace.panes
                    .filter {
                        unreadIDs.contains($0.id)
                            && (workspaceMatches
                                || matchingTabIDs.contains($0.scopedTabID)
                                || matchesPaneQuery($0, query: trimmedQuery))
                            && recency.includes($0, now: now, calendar: calendar)
                    }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return UnreadGroup(workspace: workspace, chats: chats)
            }
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
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MachineGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.map { machine in
            MachineGroup(
                machine: machine,
                state: states[machine.id] ?? .disconnected,
                isExpanded: trimmedQuery.isEmpty ? !collapsedMachineIDs.contains(machine.id) : true,
                entries: build(
                    workspaces: workspaces.filter { $0.machineID == machine.id },
                    query: query,
                    collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                    collapsedTabIDs: collapsedTabIDs,
                    starredIDs: starredIDs,
                    recency: recency,
                    excludedPaneIDs: excludedPaneIDs,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    static func staleGroups(
        machines: [HerdrMachine],
        workspaces: [HerdrWorkspace],
        query: String,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [StaleGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.compactMap { machine in
            let chats = workspaces
                .filter { $0.machineID == machine.id }
                .flatMap { workspace -> [HerdrPane] in
                    let workspaceMatches = trimmedQuery.isEmpty
                        || workspace.label.localizedStandardContains(trimmedQuery)
                        || workspace.displayPath.localizedStandardContains(trimmedQuery)
                    let matchingTabIDs = Set(workspace.tabs.filter {
                        $0.label.localizedStandardContains(trimmedQuery)
                    }.map(\.id))
                    return workspace.panes.filter { pane in
                        !excludedPaneIDs.contains(pane.id)
                            && PaneFreshness.isStale(pane, now: now, calendar: calendar)
                            && (workspaceMatches
                                || matchingTabIDs.contains(pane.scopedTabID)
                                || matchesPaneQuery(pane, query: trimmedQuery))
                    }
                }
                .sorted {
                    if $0.lastActivityAt != $1.lastActivityAt {
                        return ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
                    }
                    return $0.id < $1.id
                }
            guard !chats.isEmpty else { return nil }
            return StaleGroup(machine: machine, chats: chats)
        }
    }

    /// The flat "Recents" list ranks the fleet's newest chats instead of
    /// applying a range predicate. Rebuilding it under workspace chrome would
    /// erase the only order the mode has to offer.
    static func recentChats(
        workspaces: [HerdrWorkspace],
        query: String,
        limit: Int = SidebarRecency.recentsLimit
    ) -> [HerdrPane] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(workspaces.flatMap { workspace in
            let workspaceMatches = trimmedQuery.isEmpty
                || workspace.label.localizedStandardContains(trimmedQuery)
                || workspace.displayPath.localizedStandardContains(trimmedQuery)
            let matchingTabIDs = Set(workspace.tabs.filter {
                $0.label.localizedStandardContains(trimmedQuery)
            }.map(\.id))
            return workspace.panes.filter {
                workspaceMatches
                    || matchingTabIDs.contains($0.scopedTabID)
                    || matchesPaneQuery($0, query: trimmedQuery)
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

    private static func buildEntry(
        for workspace: HerdrWorkspace,
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String>,
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> ProjectEntry? {
        let sortedTabs = workspace.tabs.sorted { $0.number < $1.number }
        let tabIDs = Set(sortedTabs.map(\.id))
        let workspaceMatches: Bool
        let matchingTabIDs: Set<String>
        let matchingPaneIDs: Set<String>
        if query.isEmpty {
            workspaceMatches = false
            matchingTabIDs = []
            matchingPaneIDs = []
        } else {
            workspaceMatches = workspace.label.localizedStandardContains(query)
                || workspace.displayPath.localizedStandardContains(query)
            matchingTabIDs = Set(sortedTabs.filter {
                $0.label.localizedStandardContains(query)
            }.map(\.id))
            matchingPaneIDs = Set(workspace.panes.filter {
                matchesPaneQuery($0, query: query)
                    && !excludedPaneIDs.contains($0.id)
                    && recency.includes($0, now: now, calendar: calendar)
            }.map(\.id))
        }

        guard query.isEmpty || workspaceMatches || !matchingTabIDs.isEmpty || !matchingPaneIDs.isEmpty else {
            return nil
        }

        let filteredPanes: [HerdrPane]
        if query.isEmpty || workspaceMatches {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && !excludedPaneIDs.contains($0.id)
                    && recency.includes($0, now: now, calendar: calendar)
            }
        } else {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && !excludedPaneIDs.contains($0.id)
                    && (matchingPaneIDs.contains($0.id) || matchingTabIDs.contains($0.scopedTabID))
                    && recency.includes($0, now: now, calendar: calendar)
            }
        }

        let filtersPanes = recency != .all || !excludedPaneIDs.isEmpty

        let sections = sortedTabs.compactMap { tab -> SectionEntry? in
            let chats = filteredPanes
                .filter { $0.scopedTabID == tab.id }
                .sorted { $0.paneID < $1.paneID }
            guard (query.isEmpty && !filtersPanes) || !chats.isEmpty || (!filtersPanes && matchingTabIDs.contains(tab.id)) else { return nil }
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

    private static func matchesPaneQuery(_ pane: HerdrPane, query: String) -> Bool {
        query.isEmpty || pane.displayTitle.localizedStandardContains(query)
    }

}
