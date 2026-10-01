import Foundation
import Testing
import UserNotifications
@testable import herdr_harness_mac

@MainActor
@Suite("Saved PR walkthroughs", .serialized)
struct PRReviewSavedWalkthroughTests {
    private let guideID = "prguide_" + String(repeating: "a", count: 24)

    private func summary(_ state: String, isNew: Bool, id: String? = nil, headSHA: String? = nil) -> PRReviewWalkthroughSummary {
        let review = PRReviewDemo.snapshot().review
        return .init(id: id ?? guideID, state: state, baseSHA: review.baseSHA, headSHA: headSHA ?? review.headSHA,
                     comparisonID: nil, createdAt: "2026-10-01T11:00:00Z", finishedAt: state == "running" ? nil : "2026-10-01T11:05:00Z",
                     seenAt: nil, error: state == "failed" ? "The buddy could not finish." : nil,
                     chapterCount: state == "finished" ? 3 : 0, needsAttention: isNew)
    }

    private func guide(_ state: String) -> PRReviewGuide {
        let review = PRReviewDemo.snapshot().review
        var guide = PRReviewGuideDemo.make(scope: .init(machineID: "synthetic-host", reviewID: review.id, baseSHA: review.baseSHA, headSHA: review.headSHA))
        guide.id = guideID
        guide.state = state
        if state != "finished" { guide.chapters = [] }
        return guide
    }

    /// A live store on a companion with saved walkthroughs, showing the demo
    /// review. The store's own session is the one under test.
    private func configured(_ client: TestPRReviewClient, walkthrough: PRReviewWalkthroughSummary?,
                            presented: Bool = true) throws -> (PRReviewStore, PRReviewGuideSession) {
        let store = PRReviewStore()
        store.guide.isAppActive = { true }
        store.guide.setPresented(presented)
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        var snapshot = PRReviewDemo.snapshot()
        snapshot.review.walkthrough = walkthrough
        store.reviews = [snapshot.review]
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data("""
            {"ok":true,"available":true,"capabilities":["pr-review-v1","pr-review-guide-v1","pr-review-walkthroughs-v1"],"skills":[]}
            """.utf8))
        store.receive(snapshot)
        return (store, store.guide)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Opening a review loads its saved walkthrough and clears the badge")
    func loadsSavedWalkthrough() async throws {
        let client = TestPRReviewClient()
        client.savedWalkthroughs = [summary("finished", isNew: true)]
        client.savedGuides = [guideID: [guide("finished")]]
        let (store, session) = try configured(client, walkthrough: summary("finished", isNew: true))
        #expect(store.walkthroughAttentionCount == 1)
        try await eventually { session.plan != nil && store.walkthroughAttentionCount == 0 }
        #expect(session.plan?.id == guideID)
        #expect(session.chapters.count == 3)
        #expect(session.chapterIndex == 0)
        #expect(!session.isBusy)
        #expect(client.seenWalkthroughIDs == [guideID])
        #expect(store.walkthroughAttentionCount == 0)
        #expect(store.snapshot?.review.walkthrough?.isNew == false)
        session.suspend()
    }

    @Test("A walkthrough still preparing on the companion is followed until it is ready")
    func followsRunningWalkthrough() async throws {
        let client = TestPRReviewClient()
        client.savedWalkthroughs = [summary("running", isNew: false)]
        client.savedGuides = [guideID: [guide("running"), guide("finished")]]
        let (_, session) = try configured(client, walkthrough: summary("running", isNew: false))
        try await eventually { session.pendingWalkthroughID != nil }
        #expect(session.isBusy)
        #expect(session.status.contains("You can leave this review"))
        try await eventually { session.plan != nil }
        #expect(session.plan?.id == guideID)
        #expect(session.pendingWalkthroughID == nil)
        #expect(!session.isBusy)
        session.suspend()
    }

    @Test("Only a review on screen in the active app is acknowledged")
    func badgeWaitsForTheUser() async throws {
        let client = TestPRReviewClient()
        client.savedWalkthroughs = [summary("finished", isNew: true)]
        client.savedGuides = [guideID: [guide("finished")]]
        let (store, session) = try configured(client, walkthrough: summary("finished", isNew: true), presented: false)
        try await eventually { session.plan != nil }
        try await Task.sleep(for: .milliseconds(20))
        #expect(client.seenWalkthroughIDs.isEmpty)
        #expect(store.walkthroughAttentionCount == 1)
        var active = false
        session.isAppActive = { active }
        session.setPresented(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(client.seenWalkthroughIDs.isEmpty)
        active = true
        session.markWalkthroughSeenIfNeeded()
        try await eventually { store.walkthroughAttentionCount == 0 }
        #expect(client.seenWalkthroughIDs == [guideID])
        session.suspend()
    }

    @Test("A walkthrough for another revision is not shown, and a new failure explains itself")
    func revisionAndFailure() async throws {
        let client = TestPRReviewClient()
        client.savedWalkthroughs = [summary("failed", isNew: true), summary("finished", isNew: false, id: "prguide_" + String(repeating: "b", count: 24), headSHA: "synthetic-older-head")]
        let (_, session) = try configured(client, walkthrough: summary("failed", isNew: true), presented: false)
        try await eventually { session.error != nil }
        #expect(session.plan == nil)
        #expect(session.error == "The buddy could not finish.")
        session.suspend()
    }

    @Test("Archiving forgets this Mac's saved place for that review")
    func archiveForgetsLocalProgress() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-walkthrough-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = TestPRReviewClient()
        client.savedWalkthroughs = [summary("finished", isNew: false)]
        client.savedGuides = [guideID: [guide("finished")]]
        let (store, _) = try configured(client, walkthrough: summary("finished", isNew: false))
        let session = PRReviewGuideSession(persistenceURL: url)
        session.configure(store: store)
        try await eventually { session.plan != nil }
        session.advance()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let saved = try JSONDecoder().decode([PRReviewGuideSession.Saved].self, from: Data(contentsOf: url))
        #expect(saved.contains { $0.scope.reviewID == PRReviewDemo.reviewID })
        session.forgetSavedProgress(machineID: "synthetic-host", reviewID: PRReviewDemo.reviewID)
        #expect(session.plan == nil)
        let remaining = try JSONDecoder().decode([PRReviewGuideSession.Saved].self, from: Data(contentsOf: url))
        #expect(!remaining.contains { $0.scope.reviewID == PRReviewDemo.reviewID })
        session.suspend()
        store.guide.suspend()
    }

    @Test("Review rows describe preparing, new, and new failed walkthroughs only")
    func rowStatus() {
        #expect(PRReviewWalkthroughRowStatus(summary("running", isNew: false))?.text == "Preparing walkthrough…")
        #expect(PRReviewWalkthroughRowStatus(summary("finished", isNew: true))?.isNew == true)
        #expect(PRReviewWalkthroughRowStatus(summary("failed", isNew: true))?.text == "Walkthrough couldn’t finish")
        #expect(PRReviewWalkthroughRowStatus(summary("finished", isNew: false)) == nil)
        #expect(PRReviewWalkthroughRowStatus(nil) == nil)
        #expect(PRReviewNavigationButton.accessibilityValue(for: 2) == "2 new walkthroughs")
    }

    @Test("Walkthrough events become a banner that opens the review")
    func notificationContent() throws {
        let now = HerdrTimestamp.string(from: Date())
        let payload = JSONValue.object([
            "review_id": .string("prr_synthetic"), "guide_id": .string(guideID), "state": .string("finished"),
            "title": .string("Cache garden"), "owner": .string("example"), "repo": .string("garden"), "number": .number(42),
            "generatedAt": .string(now),
        ])
        let event = try #require(PRReviewWalkthroughNotification.Event(machineID: "synthetic-host", payload: payload))
        #expect(event.isFresh())
        let route = try #require(PRReviewWalkthroughNotification.routeURL(reviewID: event.reviewID, machineURL: "https://review.example.invalid"))
        let request = try #require(PRReviewOpenRequest(url: route))
        #expect(request.reviewID == "prr_synthetic")
        #expect(request.tab == .files)
        let content = PRReviewWalkthroughNotification.content(for: event, route: route)
        #expect(content.title == "Walkthrough ready")
        #expect(content.body == "example/garden #42 · Cache garden")
        #expect(content.userInfo[PRReviewWalkthroughNotification.routeKey] as? String == route.absoluteString)
        #expect(PRReviewWalkthroughNotification.identifier(guideID: guideID) == "pr-review-walkthrough-\(guideID)")
        guard case var .object(failed) = payload else { return }
        failed["state"] = .string("failed")
        let failure = try #require(PRReviewWalkthroughNotification.Event(machineID: "synthetic-host", payload: .object(failed)))
        #expect(PRReviewWalkthroughNotification.content(for: failure, route: nil).title == "Walkthrough couldn’t finish")
        failed["state"] = .string("running")
        #expect(PRReviewWalkthroughNotification.Event(machineID: "synthetic-host", payload: .object(failed)) == nil)
        failed["state"] = .string("finished")
        failed["generatedAt"] = .string("2026-01-01T00:00:00Z")
        #expect(PRReviewWalkthroughNotification.Event(machineID: "synthetic-host", payload: .object(failed))?.isFresh() == false)
    }
}
