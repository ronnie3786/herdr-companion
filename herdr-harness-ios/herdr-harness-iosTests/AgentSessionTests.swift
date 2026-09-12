import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Agent session cards")
struct AgentSessionTests {
    @Test("All Pi sessions rank across machines without a twenty-session limit")
    func rankingAndIdentity() throws {
        let desktop = try workspace(machine: "desktop", count: 25)
        let laptop = try workspace(machine: "laptop", count: 1)
        let sessions = AgentSession.recent(workspaces: [desktop, laptop], machines: [], query: "")
        #expect(sessions.count == 26)
        #expect(sessions.first?.id == "desktop|w1:p24")
        #expect(Set(sessions.map(\.id)).count == 26)
        #expect(sessions.suffix(2).map(\.id) == ["desktop|w1:p0", "laptop|w1:p0"])
    }

    @Test("Search includes machine, workspace, tab, title, agent and status")
    func searchContext() throws {
        let workspace = try workspace(machine: "desktop", count: 1)
        let machines = [HerdrMachine(id: "desktop", name: "Studio", urlString: "https://desktop.example.invalid")]
        for query in [" studio ", "Garden", "Planning", "Session 0", "PI", "Working"] {
            let result = AgentSession.recent(workspaces: [workspace], machines: machines, query: query)
            #expect(result.count == 1)
            #expect(result.first?.tabName == "Planning")
        }
        #expect(AgentSession.recent(workspaces: [workspace], machines: machines, query: "missing").isEmpty)
    }

    @Test("Shells and other agents are excluded while semantic Pi and legacy Pi are included")
    func piEligibility() throws {
        let data = Data("""
        {"workspace_id":"w1","panes":[
          {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"t1","agent":"pi"},
          {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"t1","display_agent":"PI"},
          {"pane_id":"w1:p3","workspace_id":"w1","tab_id":"t1","agent":"Claude"},
          {"pane_id":"w1:p4","workspace_id":"w1","tab_id":"t1"},
          {"pane_id":"w1:p5","workspace_id":"w1","tab_id":"t1","agent":"pi","reserved_shell":true},
          {"pane_id":"w1:p6","workspace_id":"w1","tab_id":"t1","pi_semantic":{"available":true,"protocolVersion":1}}
        ]}
        """.utf8)
        let workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: data)
        let sessions = AgentSession.recent(workspaces: [workspace], machines: [], query: "")
        #expect(sessions.map(\.id) == ["w1:p1", "w1:p2", "w1:p6"])
        #expect(sessions.first?.machineName == "Unknown machine")
        #expect(sessions.first?.tabName == "Untitled tab")
    }

    private func workspace(machine: String, count: Int) throws -> HerdrWorkspace {
        let panes = (0..<count).map { index -> [String: Any] in
            ["pane_id": "w1:p\(index)", "workspace_id": "w1", "tab_id": "w1:t1",
             "agent": "Pi", "title": "Session \(index)", "agent_status": "working",
             "last_activity_at": HerdrTimestamp.string(from: Date(timeIntervalSince1970: Double(index))) ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "workspace_id": "w1", "label": "Garden", "panes": panes,
            "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "label": "Planning", "number": 1, "focused": false, "pane_count": count, "agent_status": "working"]],
        ])
        return try JSONDecoder().decode(HerdrWorkspace.self, from: data).stamped(machineID: machine)
    }
}
