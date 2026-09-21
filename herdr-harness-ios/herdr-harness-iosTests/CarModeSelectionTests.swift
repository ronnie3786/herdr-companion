import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Car mode selection")
struct CarModeSelectionTests {
    @Test("Needs-you first, then ready, working, and idle, newest first inside a rank")
    func ranksByUrgencyThenRecency() throws {
        let workspace = try workspace(machine: "desktop", panes: [
            .init(id: "p1", status: .idle, title: "Fictional weather notes", activity: 60),
            .init(id: "p2", status: .working, title: "Fictional garden layout", activity: 50),
            .init(id: "p3", status: .blocked, title: "Fictional reading choices", activity: 10),
            .init(id: "p4", status: .done, title: "Fictional export", activity: 30),
            .init(id: "p5", status: .working, title: "Fictional seed list", activity: 40),
        ])

        let sessions = CarModeSelection.entries(workspaces: [workspace], machines: [])

        #expect(sessions.map(\.id) == ["desktop|w1:p3", "desktop|w1:p4", "desktop|w1:p2", "desktop|w1:p5"])
    }

    @Test("Caps at the requested number of agents")
    func honoursLimit() throws {
        let workspace = try workspace(machine: "desktop", panes: [
            .init(id: "p1", status: .working, title: "A", activity: 10),
            .init(id: "p2", status: .working, title: "B", activity: 20),
            .init(id: "p3", status: .working, title: "C", activity: 30),
            .init(id: "p4", status: .working, title: "D", activity: 40),
            .init(id: "p5", status: .working, title: "E", activity: 50),
        ])

        #expect(CarModeSelection.entries(workspaces: [workspace], machines: []).count == 4)
        #expect(
            CarModeSelection.entries(workspaces: [workspace], machines: [], limit: 2)
                .map(\.id) == ["desktop|w1:p5", "desktop|w1:p4"]
        )
        #expect(CarModePreferences.defaultAgentLimit == 4)
        #expect(CarModePreferences.allowedAgentLimits == [2, 4, 6])
    }

    @Test("Only the newest twenty chats can appear, exactly as the Agents tab ranks them")
    func staysInsideTheRecentsWindow() throws {
        let workspace = try workspace(machine: "desktop", panes: (1...25).map { index in
            PaneSpec(id: "p\(index)", status: .working, title: "Session \(index)", activity: Double(index))
        })

        // The newest twenty panes form the window; a request inside it is capped
        // by the request, and a request past it stops at the window.
        let topSix = CarModeSelection.entries(workspaces: [workspace], machines: [], limit: 6)
        #expect(topSix.map(\.id) == [
            "desktop|w1:p25", "desktop|w1:p24", "desktop|w1:p23", "desktop|w1:p22", "desktop|w1:p21", "desktop|w1:p20",
        ])

        let everything = CarModeSelection.entries(workspaces: [workspace], machines: [], limit: 21)
        #expect(everything.count == SidebarRecency.recentsLimit)
        #expect(everything.last?.id == "desktop|w1:p6")
        #expect(!everything.contains { $0.pane.paneID == "p5" }, "Older chats stay out of the window")
    }

    @Test("Shells and non-agent panes stay out of Car mode")
    func excludesNonAgentPanes() throws {
        let workspace = try workspace(machine: "desktop", panes: [
            .init(id: "p1", status: .working, title: "Fictional terminal", activity: 100, agent: nil, piSemantic: false),
            .init(id: "p2", status: .working, title: "Fictional shell", activity: 90, reservedShell: true),
            .init(id: "p3", status: .working, title: "Fictional agent", activity: 80),
        ])

        let sessions = CarModeSelection.entries(workspaces: [workspace], machines: [])

        #expect(sessions.map(\.id) == ["desktop|w1:p3"])
    }

    @Test("Identically named workspaces on different machines stay separate")
    func keepsMachinesApart() throws {
        let desktop = try workspace(
            machine: "desktop",
            label: "Garden",
            panes: [.init(id: "p1", status: .working, title: "A", activity: 10)]
        )
        let laptop = try workspace(
            machine: "laptop",
            label: "Garden",
            panes: [.init(id: "p1", status: .blocked, title: "B", activity: 20)]
        )

        let sessions = CarModeSelection.entries(workspaces: [desktop, laptop], machines: [])

        #expect(sessions.map(\.id) == ["laptop|w1:p1", "desktop|w1:p1"])
        #expect(Set(sessions.map(\.workspace.id)).count == 2)
    }

    @Test("Unknown panes sort last, after idle ones")
    func unknownSortsLast() {
        #expect(CarModeSelection.rank(for: .blocked) == 0)
        #expect(CarModeSelection.rank(for: .done) == 1)
        #expect(CarModeSelection.rank(for: .working) == 2)
        #expect(CarModeSelection.rank(for: .idle) == 3)
        #expect(CarModeSelection.rank(for: .unknown) == 4)
    }

    // MARK: - Fixtures

    private struct PaneSpec {
        let id: String
        var status: AgentStatus = .working
        var title: String = "Fictional garden task"
        var activity: Double = 0
        var agent: String? = "Pi"
        var piSemantic: Bool = true
        var reservedShell: Bool = false
    }

    private func workspace(
        machine: String,
        label: String = "Garden Planner",
        panes: [PaneSpec]
    ) throws -> HerdrWorkspace {
        let base = Date(timeIntervalSince1970: 1_900_000_000)
        let panePayloads: [[String: Any]] = panes.map { pane in
            var payload: [String: Any] = [
                "pane_id": "w1:\(pane.id)",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "agent_status": pane.status.rawValue,
                "title": pane.title,
                "last_activity_at": ISO8601DateFormatter().string(
                    from: base.addingTimeInterval(pane.activity)
                ),
                "reserved_shell": pane.reservedShell,
            ]
            if let agent = pane.agent { payload["agent"] = agent }
            if pane.piSemantic {
                payload["pi_semantic"] = [
                    "available": true,
                    "connected": true,
                    "protocolVersion": 1,
                    "sessionId": "session-\(pane.id)",
                ]
            }
            return payload
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "workspace_id": "w1",
            "label": label,
            "panes": panePayloads,
        ])
        let workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: data)
        // `HerdrPane.machineID` drives the scoped IDs Car mode preserves.
        return workspace.stamped(machineID: machine)
    }
}
