import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Dashboard behavior", .serialized)
@MainActor
struct DashboardTests {
    @Test("Equal message timestamps preserve the server conversation order")
    func timelineOrder() {
        let snapshot = FirstMateDemo.features(step: 2)[0]
        let messageIDs = AgentBoardTimelineItem.items(in: snapshot).compactMap { item -> String? in
            if case .message(let message) = item { return message.id }
            return nil
        }
        #expect(messageIDs == snapshot.messages.map(\.id))
    }

    @Test("Dashboard launches first and both new destinations survive navigation history")
    func navigation() throws {
        let defaults = isolatedDefaults()
        let shell = HerdrShellState(userDefaults: defaults)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        #expect(shell.detailScope == .dashboard)
        #expect(shell.resolvedScope(for: model) == .dashboard)
        shell.recordVisit(for: model)
        shell.show(.agentBoard, model: model)
        shell.show(.firstMate, model: model)
        #expect(shell.goBack(model: model))
        #expect(shell.detailScope == .agentBoard)
        #expect(shell.goBack(model: model))
        #expect(shell.detailScope == .dashboard)
        #expect(shell.goForward(model: model))
        #expect(shell.detailScope == .agentBoard)
        #expect(HerdrDestinationRecord(.dashboard)?.destination == .dashboard)
        #expect(HerdrDestinationRecord(.agentBoard)?.destination == .agentBoard)
        #expect(HerdrDetailScope.pickerSelection(for: .dashboard) == nil)
        let pane = try #require(model.workspaces.first?.panes.first)
        shell.openPane(id: pane.id, model: model)
        #expect(shell.resolvedScope(for: model) == .session)
        #expect(model.selectedPaneID == pane.id)
    }

    @Test("Focus hides nonwaiting work, rejects unknown states, and respects machine identity")
    func featureFiltering() {
        let statuses = ["paused", "running", "blocked", "awaiting_direction", "recovering", "future_status", "completed", "cancelled", "archived"]
        var entries = statuses.map { entry($0) }
        entries.append(entry("awaiting_direction", machineID: "other"))
        entries.append(entries[2])
        let focused = DashboardFeatureEntry.ordered(entries, focusMode: true)
        #expect(focused.map(\.feature.status) == ["awaiting_direction", "awaiting_direction", "blocked"])
        #expect(Set(focused.map(\.id)).count == 3)
        #expect(DashboardFeatureEntry.ordered(entries).count == 7)
        #expect(DashboardFeatureEntry.ordered(entries, query: "running").count == 1)
        var archived = entry("blocked")
        var feature = archived.feature
        feature.archivedAt = "2026-01-01T00:00:00Z"
        archived = .init(machineID: "a", machineName: "A", feature: feature)
        #expect(DashboardFeatureEntry.ordered([archived], focusMode: true).isEmpty)
    }

    @Test("Focus mode and the independent chat machine filter survive relaunch")
    func persistence() {
        let defaults = isolatedDefaults()
        let state = DashboardState(defaults: defaults)
        state.focusMode = true
        state.recentMachineID = "synthetic-machine"
        let restored = DashboardState(defaults: defaults)
        #expect(restored.focusMode)
        #expect(restored.recentMachineID == "synthetic-machine")
    }

    @Test("Review filtering never confuses approval or unavailable data with waiting for me")
    func reviewFiltering() throws {
        var reviews = try ["approved", "pending", "re_review_requested", "not_reviewed", "unknown", "future_state"].enumerated().map { index, status in
            var review = try JSONDecoder().decode(PRReviewSummary.self, from: Data("{\"id\":\"review-\(index)\"}".utf8))
            review.viewerReview = .init(state: status, needsUser: true)
            return review
        }
        var own = reviews[1]
        own.id = "own"
        own.viewerReview?.isOwnPR = true
        reviews.append(own)
        var archived = reviews[2]
        archived.id = "archived"
        archived.archivedAt = "2026-01-01T00:00:00Z"
        reviews.append(archived)
        #expect(DashboardReviewPresentation.filtered(reviews, focusMode: true, query: "").map(\.id) == ["review-1", "review-2"])
        #expect(DashboardReviewPresentation.filtered(reviews, focusMode: false, query: "").count == 6)
        #expect(DashboardReviewState(state: "future", needsUser: true).needsAttention == false)
    }

    @Test("Old companion payloads remain decodable without dashboard fields")
    func compatibility() throws {
        let feature = entry("running").feature
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature)) as? [String: Any])
        object.removeValue(forKey: "dashboard_summary")
        let decoded = try JSONDecoder().decode(FirstMateFeature.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.dashboardSummary == nil)
        let review = try JSONDecoder().decode(PRReviewSummary.self, from: Data("{\"id\":\"legacy\"}".utf8))
        #expect(review.viewerReview == nil)
        #expect(review.skillRuns == nil)
        #expect(DashboardReviewPresentation.filtered([review], focusMode: true, query: "").isEmpty)
    }

    @Test("Dashboard cards open the owning machine and Overview")
    func firstMateRouting() {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        shell.showFirstMate(machineID: "machine-b", featureID: "same-id", inspector: .overview, model: model)
        #expect(shell.detailScope == .firstMate)
        #expect(shell.firstMateMachineID == "machine-b")
        #expect(shell.pendingFirstMateControlTarget?.featureID == "same-id")
        #expect(shell.pendingFirstMateControlTarget?.inspector == .overview)
    }

    @Test("Older equal-revision snapshots cannot replace newer GitHub viewer state")
    func reviewFreshness() async {
        let store = PRReviewStore()
        store.configure(client: TestPRReviewClient(), machineID: "synthetic", demo: false)
        var old = PRReviewDemo.snapshot()
        old.review.viewerReview = .init(state: "pending", checkedAt: "2026-01-01T00:00:00Z")
        store.receive(old)
        store.reviews[0].viewerReview = .init(state: "approved", checkedAt: "2026-01-01T00:01:00Z")
        store.receive(old)
        #expect(store.reviews[0].viewerReview?.state == "approved")
        #expect(store.snapshot?.review.viewerReview?.state == "approved")
        var failed = old.review
        failed.viewerReview = .init(state: "approved", checkedAt: "2026-01-01T00:02:00Z", error: "Offline")
        #expect(failed.retainingNewerViewerState(from: store.reviews[0]).viewerReview?.error == "Offline")
        // The newer failed attempt stays stale instead of an old success erasing its warning.
        #expect(old.review.retainingNewerViewerState(from: failed).viewerReview?.error == "Offline")
        store.unsupported = true
        _ = await store.refreshDashboard()
        #expect(!store.unsupported)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DashboardTests.\(UUID().uuidString)")!
    }
    private func entry(_ status: String, machineID: String = "synthetic") -> DashboardFeatureEntry {
        let feature = FirstMateFeature(id: status, title: status, goal: "Synthetic goal", cwd: "/tmp/synthetic", status: status,
            currentVisitID: nil, revision: 1, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        return .init(machineID: machineID, machineName: "Synthetic Mac", feature: feature)
    }
}
