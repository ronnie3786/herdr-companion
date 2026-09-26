import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Synthetic, realistic fixtures: ticket-prefixed titles, markdown and HTML
/// entities in server text, and thousands of Pi telemetry events that must
/// never reach the screen.
@Suite("Dashboard renders", .serialized)
@MainActor
struct DashboardRenderTests {
    @Test("Dashboard at narrow, default, and wide widths, plus Focus mode")
    func dashboard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "DashboardRender.\(UUID())")!)
        shell.firstMate.configure(client: nil, demo: true)
        shell.prReview.configure(client: nil, machineID: "demo", demo: true)
        await shell.prReview.refresh()
        seed(shell: shell)
        for (name, width, focus) in [("dashboard-default", 1280.0, false), ("dashboard-narrow", 1000.0, false),
                                     ("dashboard-wide", 1764.0, false), ("dashboard-focus", 1280.0, true)] {
            shell.dashboard.focusMode = focus
            let image = try await HerdrRenderHarness.render("\(name).png", size: CGSize(width: width, height: 900)) {
                DashboardView(model: model, shell: shell)
            }
            image.expectSubstantial()
        }
    }

    @Test("Agent view columns render from bounded content at several widths")
    func agentBoard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "AgentBoardRender.\(UUID())")!)
        shell.firstMate.configure(client: nil, demo: true)
        let entries = seed(shell: shell)
        for (index, entry) in entries.enumerated() {
            let column = shell.agentBoard.column(for: entry)
            column.configure(configuration: nil, generation: 0, demo: true, client: nil,
                             demoSnapshot: shell.firstMate.snapshots[entry.feature.id])
            if index == 2 { column.tab = .overview }
            if index == 3 { column.tab = .agents }
            if index == 4 { column.tab = .workflow }
            let content = try #require(column.content)
            #expect(content.latestNotes.allSatisfy { !$0.text.hasPrefix("Telemetry") })
        }
        for (name, size) in [("agent-board-default", CGSize(width: 1280, height: 860)),
                             ("agent-board-wide", CGSize(width: 1764, height: 1100)),
                             ("agent-board-narrow", CGSize(width: 1000, height: 760))] {
            let image = try await HerdrRenderHarness.render("\(name).png", size: size) {
                AgentBoardView(model: model, shell: shell)
            }
            image.expectSubstantial()
        }
    }

    @discardableResult
    private func seed(shell: HerdrShellState) -> [DashboardFeatureEntry] {
        let titles = ["DEMO-104 — Offline garden notes", "Settings screen refresh", "Weather retry queue",
                      "Faster seed search", "Watering reminder copy"]
        let statuses = ["awaiting_direction", "blocked", "running", "coordinating", "paused"]
        let base = Date.now.addingTimeInterval(-3_600)
        for (index, title) in titles.enumerated() {
            var snapshot = FirstMateDemo.features(step: index % 4)[0]
            let id = "demo-dashboard-\(index)"
            snapshot.feature.id = id
            snapshot.feature.title = title
            snapshot.feature.status = statuses[index]
            snapshot.feature.updatedAt = HerdrTimestamp.string(from: Date.now.addingTimeInterval(Double(-index * 60)))
            for i in snapshot.visits.indices { snapshot.visits[i].featureID = id }
            for i in snapshot.assignments.indices {
                snapshot.assignments[i].featureID = id
                snapshot.assignments[i].role = i == 0 ? "iOS platform &amp; architecture lead" : snapshot.assignments[i].role
            }
            for i in snapshot.messages.indices { snapshot.messages[i].featureID = id }
            snapshot.messages.append(.init(
                id: "\(id)-markdown", featureID: id, role: "assistant",
                text: "The second review is in — **PR #12032 is now approved**.\n\n- Two approvals\n- `ios_core` still pending\n\nWant me to merge?",
                status: "done", createdAt: HerdrTimestamp.string(from: base.addingTimeInterval(3_000))))
            snapshot.events = snapshot.events.map { event in
                var event = event
                event.featureID = id
                return event
            } + (1...2_000).map { n in
                FirstMateEvent(sequence: 10_000 + n, id: "\(id)-t\(n)", featureID: id, type: "pi.tool_execution_end",
                               summary: "Telemetry \(n)", createdAt: HerdrTimestamp.string(from: base.addingTimeInterval(Double(n))))
            }
            var summary = FirstMateDashboardSummary.from(snapshot)
            summary.activityAt = snapshot.feature.updatedAt
            if statuses[index] == "awaiting_direction" || statuses[index] == "blocked" {
                summary.needsUserPrompt = "Choose **A** (merge now) or **B** (wait for `ios_core`)."
            }
            snapshot.feature.dashboardSummary = summary
            shell.firstMate.receive(snapshot)
        }
        return shell.dashboard.entries(shell: shell, isDemo: true)
    }
}
