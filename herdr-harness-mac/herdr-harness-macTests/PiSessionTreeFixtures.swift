import Foundation
@testable import herdr_harness_mac

enum PiSessionTreeFixtures {
    static func workspaces() throws -> [HerdrWorkspace] {
        let specifications = [
            ("garden", "Garden Planner", [
                try pane("garden:p1", session: "plan-session", title: "Plan the sample garden", recent: true),
                try pane("garden:p2", session: "colors-session", parent: "plan-session", title: "Choose the garden colors", recent: true),
            ]),
            ("weather", "Weather Samples", [
                try pane("weather:p1", session: "weather-session", parent: "plan-session", title: "Check rainfall for the garden", recent: true),
                try pane("weather:p2", session: "review-session", parent: "weather-session", title: "Review the sample readings", recent: true),
            ]),
        ]
        return try specifications.enumerated().map { index, item in
            let object: [String: Any] = [
                "workspace_id": item.0, "label": item.1, "number": index,
                "pane_count": item.2.count,
                "tabs": [[
                    "tab_id": "\(item.0):t1", "workspace_id": item.0, "label": "Pi sessions",
                    "pane_count": item.2.count, "number": 1, "focused": false, "agent_status": "working",
                ]],
            ]
            var workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
            workspace.panes = item.2
            return workspace.stamped(machineID: "demo1")
        }
    }

    static func pane(_ id: String, session: String, parent: String? = nil, title: String = "Sample session", recent: Bool = false) throws -> HerdrPane {
        let workspace = String(id.split(separator: ":")[0])
        var capability: [String: Any] = ["session_id": session]
        if let parent { capability["parent_session_id"] = parent }
        var object: [String: Any] = [
            "pane_id": id, "workspace_id": workspace, "tab_id": "\(workspace):t1",
            "label": title, "agent": "pi", "agent_status": "working", "pi_semantic": capability,
            "cwd": "/tmp/herdr-demo/\(workspace)",
        ]
        if recent { object["last_activity_at"] = HerdrTimestamp.string(from: Date()) }
        return try JSONDecoder().decode(HerdrPane.self, from: JSONSerialization.data(withJSONObject: object)).stamped(machineID: "demo1")
    }
}
