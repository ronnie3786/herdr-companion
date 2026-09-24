import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Dashboard renders", .serialized)
@MainActor
struct DashboardRenderTests {
    @Test("Purple Dashboard at desktop and narrow widths, plus Focus mode")
    func dashboard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "DashboardRender.\(UUID())")!)
        shell.firstMate.configure(client: nil, demo: true)
        shell.prReview.configure(client: nil, machineID: "demo", demo: true)
        await shell.prReview.refresh()
        let entries = fixtures(shell: shell)
        for (name, width, focus) in [("dashboard-purple", 1280.0, false), ("dashboard-narrow", 860.0, false), ("dashboard-focus", 1280.0, true)] {
            shell.dashboard.focusMode = focus
            let image = try await HerdrRenderHarness.render("\(name).png", size: CGSize(width: width, height: 900)) {
                DashboardView(model: model, shell: shell, entries: entries)
            }
            image.expectSubstantial()
        }
    }

    @Test("Agent columns render using synthetic snapshots")
    func agentBoard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "AgentBoardRender.\(UUID())")!)
        shell.firstMate.configure(client: nil, demo: true)
        let entries = fixtures(shell: shell)
        let image = try await HerdrRenderHarness.render("dashboard-agent-board.png", size: CGSize(width: 1280, height: 900)) {
            AgentBoardView(model: model, shell: shell, entries: entries)
        }
        image.expectSubstantial()
    }

    private func fixtures(shell: HerdrShellState) -> [DashboardFeatureEntry] {
        let titles = ["Offline garden notes", "Settings screen refresh", "Weather retry queue", "Faster seed search", "Watering reminder copy"]
        let statuses = ["awaiting_direction", "blocked", "running", "coordinating", "paused"]
        return titles.enumerated().map { index, title in
            var snapshot = FirstMateDemo.features(step: index % 4)[0]
            snapshot.feature.id = "demo-dashboard-\(index)"
            snapshot.feature.title = title
            snapshot.feature.status = statuses[index]
            snapshot.feature.updatedAt = HerdrTimestamp.string(from: Date.now.addingTimeInterval(Double(-index * 60)))
            snapshot.feature.dashboardSummary = .from(snapshot)
            snapshot.feature.dashboardSummary?.stageCountIsEstimate = false
            snapshot.feature.dashboardSummary?.stageCount = 5
            snapshot.feature.dashboardSummary?.currentStageIndex = index % 3 + 1
            for i in snapshot.visits.indices { snapshot.visits[i].featureID = snapshot.feature.id }
            for i in snapshot.assignments.indices { snapshot.assignments[i].featureID = snapshot.feature.id }
            for i in snapshot.messages.indices { snapshot.messages[i].featureID = snapshot.feature.id }
            for i in snapshot.events.indices { snapshot.events[i].featureID = snapshot.feature.id }
            shell.firstMate.receive(snapshot)
            let entry = DashboardFeatureEntry(machineID: "demo", machineName: "Demo Mac", feature: snapshot.feature)
            let column = shell.agentBoard.column(for: entry)
            column.configure(configuration: nil, generation: 0, demo: true, client: nil, demoSnapshot: snapshot)
            if index == 2 { column.tab = .overview }
            if index == 3 { column.tab = .workflow }
            return entry
        }
    }
}
