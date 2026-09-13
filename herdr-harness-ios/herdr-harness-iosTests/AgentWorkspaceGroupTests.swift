import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Grouped agent workspaces")
struct AgentWorkspaceGroupTests {
    @Test("Workspace and tab groups rank by their newest chat without losing interleaved sessions")
    func groupingAndRecency() throws {
        let workspaces = try fixtures()
        let groups = AgentWorkspaceGroup.recent(workspaces: workspaces, machines: [], query: "")
        #expect(groups.map(\.id) == ["desktop|w1", "desktop|w2", "laptop|w1"])
        #expect(groups.map(\.sessionCount) == [3, 1, 1])
        #expect(groups[0].tabs.map(\.id) == ["desktop|w1:t1", "desktop|w1:t2"])
        #expect(groups[0].tabs[0].sessions.map(\.id) == ["desktop|w1:p1", "desktop|w1:p4"])
        #expect(groups[0].tabs[1].sessions.map(\.id) == ["desktop|w1:p3"])
        let ids = groups.flatMap { $0.tabs.flatMap { $0.sessions.map(\.id) } }
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        // Same labels and raw IDs on another machine must never merge.
        #expect(groups[0].workspace.label == groups[2].workspace.label)
        #expect(groups[2].tabs[0].id == "laptop|w1:t1")
    }

    @Test("Search ranks groups by matching chats and removes empty groups and tabs")
    func filteredGroups() throws {
        let groups = AgentWorkspaceGroup.recent(workspaces: try fixtures(), machines: [], query: "match")
        #expect(groups.map(\.id) == ["desktop|w2", "desktop|w1"])
        #expect(groups.map(\.sessionCount) == [1, 1])
        #expect(groups[1].tabs.map(\.id) == ["desktop|w1:t1"])
        #expect(groups[1].tabs[0].sessions.map(\.id) == ["desktop|w1:p4"])
        #expect(AgentWorkspaceGroup.recent(workspaces: try fixtures(), machines: [], query: "absent").isEmpty)
    }

    @Test("Activity changes reorder whole workspaces while preserving sibling membership")
    func refreshedActivity() throws {
        let groups = AgentWorkspaceGroup.recent(workspaces: try fixtures(laptopActivity: 110), machines: [], query: "")
        #expect(groups.map(\.id) == ["laptop|w1", "desktop|w1", "desktop|w2"])
        #expect(groups[1].sessionCount == 3)
    }

    private func fixtures(laptopActivity: Double = 50) throws -> [HerdrWorkspace] {
        [
            try workspace(id: "w2", machine: "desktop", chats: [("p2", "t1", "Match second", 90)]),
            try workspace(id: "w1", machine: "laptop", chats: [("p1", "t1", "Laptop chat", laptopActivity)]),
            try workspace(id: "w1", machine: "desktop", chats: [
                ("p4", "t1", "Match older", 20),
                ("p3", "t2", "Another tab", 80),
                ("p1", "t1", "Newest chat", 100),
            ]),
        ]
    }

    private func workspace(id: String, machine: String, chats: [(String, String, String, Double)]) throws -> HerdrWorkspace {
        let panes: [[String: Any]] = chats.map { paneID, tabID, title, activity in
            ["pane_id": "\(id):\(paneID)", "workspace_id": id, "tab_id": "\(id):\(tabID)",
             "title": title, "agent": "Pi", "agent_status": "working",
             "last_activity_at": HerdrTimestamp.string(from: Date(timeIntervalSince1970: activity))]
        }
        let data = try JSONSerialization.data(withJSONObject: ["workspace_id": id, "label": "Shared name", "panes": panes])
        return try JSONDecoder().decode(HerdrWorkspace.self, from: data).stamped(machineID: machine)
    }
}
