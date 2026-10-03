import Foundation
import Testing
@testable import herdr_harness_mac

/// Shared transport and review regressions survive the retired Dashboard UI.
@Suite("First Mate and review compatibility", .serialized)
@MainActor
struct FirstMateReviewCompatibilityTests {
    @Test("Unknown viewer states never manufacture human attention")
    func viewerStateAttention() {
        #expect(PRReviewViewerState(state: "pending").needsAttention)
        #expect(PRReviewViewerState(state: "re_review_requested").needsAttention)
        for state in ["approved", "changes_requested", "not_reviewed", "future"] {
            #expect(!PRReviewViewerState(state: state, needsUser: true).needsAttention)
        }
    }

    @Test("Old companion payloads remain decodable without dashboard fields")
    func compatibility() throws {
        let feature = FirstMateDemo.features(step: 0)[0].feature
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature)) as? [String: Any])
        object.removeValue(forKey: "dashboard_summary")
        let decoded = try JSONDecoder().decode(FirstMateFeature.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.dashboardSummary == nil)
        let review = try JSONDecoder().decode(PRReviewSummary.self, from: Data("{\"id\":\"legacy\"}".utf8))
        #expect(review.viewerReview == nil)
        #expect(review.skillRuns == nil)
    }

    @Test("A journal-only snapshot with a server cursor is never mistaken for an older one")
    func eventCursor() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var full = FirstMateDemo.features(step: 2)[0]
        full.events = (1...10).map { FirstMateEvent(sequence: $0, id: "e\($0)", featureID: full.feature.id, type: "pi.message_end",
                                                    summary: "", createdAt: "2026-01-01T00:00:00Z") }
        store.receive(full)
        var journal = full
        journal.events = [FirstMateEvent(sequence: 4, id: "e4", featureID: full.feature.id, type: "visit.started",
                                         summary: "Started", createdAt: "2026-01-01T00:00:00Z")]
        journal.messages.append(.init(id: "new", featureID: full.feature.id, role: "assistant", text: "New reply",
                                      status: "done", createdAt: "2026-01-01T00:00:00Z"))
        journal.eventCursor = 11
        store.receive(journal)
        #expect(store.snapshots[full.feature.id]?.messages.last?.id == "new")
    }

    @Test("First Mate routing retains the exact machine and inspector")
    func firstMateRouting() {
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "FirstMateReviewCompatibility.\(UUID())")!)
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
}
