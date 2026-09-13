import Foundation

struct AgentWorkspaceGroup: Identifiable {
    let workspace: HerdrWorkspace
    let machineName: String
    let tabs: [AgentTabGroup]

    var id: String { workspace.id }
    var sessionCount: Int { tabs.reduce(0) { $0 + $1.sessions.count } }

    static func recent(workspaces: [HerdrWorkspace], machines: [HerdrMachine], query: String) -> [Self] {
        let sessions = AgentSession.recent(workspaces: workspaces, machines: machines, query: query)
        let byWorkspace = Dictionary(grouping: sessions, by: { $0.workspace.id })
        var seenWorkspaces = Set<String>()

        // First occurrence in the newest-first list is the group's newest chat.
        // Scoped IDs keep identically named workspaces on different machines separate.
        return sessions.compactMap { session in
            guard seenWorkspaces.insert(session.workspace.id).inserted else { return nil }
            let members = byWorkspace[session.workspace.id] ?? []
            let byTab = Dictionary(grouping: members, by: { $0.pane.scopedTabID })
            var seenTabs = Set<String>()
            let tabs = members.compactMap { member -> AgentTabGroup? in
                guard seenTabs.insert(member.pane.scopedTabID).inserted else { return nil }
                return AgentTabGroup(
                    id: member.pane.scopedTabID,
                    name: member.tabName,
                    sessions: byTab[member.pane.scopedTabID] ?? []
                )
            }
            return Self(workspace: session.workspace, machineName: session.machineName, tabs: tabs)
        }
    }
}
