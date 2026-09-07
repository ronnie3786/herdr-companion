import Foundation

/// A session has one parent. Children are derived across all workspaces on the
/// same machine, using Pi's durable session ID instead of terminal pane IDs.
struct PiSessionTree {
    struct Row: Identifiable, Equatable {
        let pane: HerdrPane
        let depth: Int
        let childCount: Int
        let isExpanded: Bool
        let workspaceLabel: String?

        var id: String { pane.id }
    }

    let panesByID: [String: HerdrPane]
    let parentByPaneID: [String: String]
    private let workspacesByID: [String: HerdrWorkspace]

    init(workspaces: [HerdrWorkspace]) {
        let panes = workspaces.flatMap(\.panes)
        panesByID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        workspacesByID = Dictionary(workspaces.map {
            (MachineScopedID.compose(machineID: $0.machineID, rawID: $0.workspaceID), $0)
        }, uniquingKeysWith: { first, _ in first })
        let sessions = Dictionary(grouping: panes.filter { Self.sessionKey(for: $0) != nil }) {
            Self.sessionKey(for: $0)!
        }
        var parents: [String: String] = [:]
        for pane in panes {
            guard let key = Self.sessionKey(for: pane), sessions[key]?.count == 1,
                  let parent = Self.nonEmpty(pane.piSemantic?.parentSessionID),
                  let candidates = sessions[MachineScopedID.compose(machineID: pane.machineID, rawID: parent)],
                  candidates.count == 1, let candidate = candidates.first,
                  candidate.id != pane.id else { continue }
            parents[pane.id] = candidate.id
        }

        // Bad or stale metadata must never hide a session or recurse forever.
        // Detach every member of a cycle; valid descendants still attach to it.
        var visited: Set<String> = []
        for start in parents.keys.sorted() where !visited.contains(start) {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var cursor: String? = start
            while let current = cursor, !visited.contains(current) {
                if let cycleStart = positions[current] {
                    for id in path[cycleStart...] { parents.removeValue(forKey: id) }
                    break
                }
                positions[current] = path.count
                path.append(current)
                cursor = parents[current]
            }
            visited.formUnion(path)
        }
        parentByPaneID = parents
    }

    var familyPaneIDs: Set<String> {
        Set(parentByPaneID.keys).union(parentByPaneID.values)
    }

    static func sessionKey(for pane: HerdrPane) -> String? {
        nonEmpty(pane.piSemantic?.sessionID).map {
            MachineScopedID.compose(machineID: pane.machineID, rawID: $0)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func ancestors(of paneID: String) -> [HerdrPane] {
        var result: [HerdrPane] = []
        var cursor = parentByPaneID[paneID]
        while let id = cursor, let pane = panesByID[id] {
            result.append(pane)
            cursor = parentByPaneID[id]
        }
        return result
    }

    func includingAncestors(of ids: Set<String>, excluding excludedIDs: Set<String>) -> Set<String> {
        var included = ids
        for id in ids {
            for ancestor in ancestors(of: id) {
                guard !excludedIDs.contains(ancestor.id) else { break }
                included.insert(ancestor.id)
            }
        }
        return included
    }

    func roots(in includedIDs: Set<String>) -> [HerdrPane] {
        includedIDs.compactMap { id in
            guard parentByPaneID[id].map({ !includedIDs.contains($0) }) ?? true else { return nil }
            return panesByID[id]
        }.sorted { $0.paneID < $1.paneID }
    }

    func rows(
        roots: [HerdrPane], includedIDs: Set<String>, collapsedSessionIDs: Set<String>
    ) -> [Row] {
        let children = Dictionary(grouping: includedIDs.compactMap { panesByID[$0] }.filter {
            parentByPaneID[$0.id].map(includedIDs.contains) ?? false
        }) { parentByPaneID[$0.id]! }
        var result: [Row] = []
        var pending = roots.reversed().map { (pane: $0, depth: 0, rootWorkspaceID: $0.workspaceID) }
        while let item = pending.popLast() {
            let descendants = (children[item.pane.id] ?? []).sorted { $0.paneID < $1.paneID }
            let expanded = Self.sessionKey(for: item.pane).map { !collapsedSessionIDs.contains($0) } ?? true
            let parentWorkspaceID = parentByPaneID[item.pane.id].flatMap { panesByID[$0]?.workspaceID }
            let differentWorkspace = item.depth > 0 && (item.pane.workspaceID != item.rootWorkspaceID
                || parentWorkspaceID != item.pane.workspaceID)
            let workspaceID = MachineScopedID.compose(machineID: item.pane.machineID, rawID: item.pane.workspaceID)
            result.append(Row(
                pane: item.pane, depth: item.depth, childCount: descendants.count,
                isExpanded: expanded,
                workspaceLabel: differentWorkspace ? (workspacesByID[workspaceID]?.label ?? item.pane.workspaceID) : nil
            ))
            if expanded {
                pending.append(contentsOf: descendants.reversed().map {
                    (pane: $0, depth: item.depth + 1, rootWorkspaceID: item.rootWorkspaceID)
                })
            }
        }
        return result
    }
}
