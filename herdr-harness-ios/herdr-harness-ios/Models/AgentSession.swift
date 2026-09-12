import Foundation

struct AgentSession: Identifiable {
    let pane: HerdrPane
    let machineName: String
    let workspace: HerdrWorkspace
    let tabName: String

    var id: String { pane.id }
    var agentName: String {
        [pane.displayAgent, pane.agent]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Pi"
    }

    static func recent(workspaces: [HerdrWorkspace], machines: [HerdrMachine], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineNames = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
        let sessions = workspaces.flatMap { workspace in
            workspace.panes.compactMap { pane -> Self? in
                guard !pane.reservedShell,
                      pane.supportsPiSemanticChat
                        || [pane.agent, pane.displayAgent].contains(where: {
                            $0?.caseInsensitiveCompare("pi") == .orderedSame
                        })
                else { return nil }
                let session = Self(
                    pane: pane,
                    machineName: machineNames[pane.machineID] ?? "Unknown machine",
                    workspace: workspace,
                    tabName: workspace.tabs.first { $0.id == pane.scopedTabID }?.label ?? "Untitled tab"
                )
                guard query.isEmpty || [
                    pane.displayTitle, session.agentName, session.machineName,
                    workspace.label, session.tabName, pane.agentStatus.compactTitle,
                ].contains(where: { $0.localizedStandardContains(query) }) else { return nil }
                return session
            }
        }
        // Match the navigator's Recents ordering, without its twenty-chat cap.
        return sessions.sorted {
            let lhs = $0.pane.lastActivityAt ?? $0.pane.firstSeenAt ?? .distantPast
            let rhs = $1.pane.lastActivityAt ?? $1.pane.firstSeenAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}
