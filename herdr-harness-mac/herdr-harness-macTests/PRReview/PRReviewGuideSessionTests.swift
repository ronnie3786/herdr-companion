import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR review buddy", .serialized)
struct PRReviewGuideSessionTests {
    private func configured(persistenceURL: URL? = nil) -> (PRReviewStore, PRReviewGuideSession) {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic-review-host", demo: true)
        store.receive(PRReviewDemo.snapshot())
        let session = PRReviewGuideSession(persistenceURL: persistenceURL)
        session.configure(store: store)
        return (store, session)
    }
    private func settle(_ session: PRReviewGuideSession) async {
        for _ in 0..<200 where session.isBusy { await Task.yield() }
    }

    @Test("Reading and audio completion never advance the chapter or mark files viewed")
    func explicitAdvance() async throws {
        let (store, session) = configured()
        let viewed = store.snapshot?.files.map(\.viewed)
        session.start(); await settle(session)
        #expect(session.chapters.count == 3)
        #expect(session.chapterIndex == 0)
        session.player.onCompletion?()
        #expect(session.chapterIndex == 0)
        #expect(session.canAdvance)
        session.advance()
        #expect(session.chapterIndex == 1)
        #expect(store.selectedPath == "Sources/Legacy/SeedCatalogMigration.swift")
        #expect(store.snapshot?.files.map(\.viewed) == viewed)
    }

    @Test("Multiple questions preserve the original walkthrough checkpoint")
    func detoursReturnToOriginalChapter() async throws {
        let (store, session) = configured()
        session.start(); await settle(session); session.advance()
        let original = session.chapter?.id
        session.beginQuestion()
        session.draft = "Why was this removed?"
        session.submitQuestion(); await settle(session)
        #expect(session.isDetour)
        #expect(session.transcript.count == 1)
        session.beginQuestion()
        session.draft = "What test would settle it?"
        session.submitQuestion(); await settle(session)
        #expect(session.transcript.count == 2)
        session.returnToWalkthrough()
        #expect(!session.isDetour)
        #expect(session.chapter?.id == original)
        #expect(session.chapterIndex == 1)
        #expect(!session.isPlaying)
        #expect(store.selectedPath == "Sources/Legacy/SeedCatalogMigration.swift")
    }

    @Test("Manual browsing offers a return path without changing the tour")
    func manualNavigation() async {
        let (_, session) = configured()
        session.start(); await settle(session)
        session.observedFileNavigation("README.md")
        #expect(session.isDetour)
        #expect(session.chapterIndex == 0)
        session.returnToWalkthrough()
        #expect(!session.isDetour)
        #expect(session.chapterIndex == 0)
    }

    @Test("An updated head keeps the old explanation readable and blocks stale actions")
    func staleScope() async {
        let (store, session) = configured()
        session.start(); await settle(session)
        let original = session.plan
        var snapshot = PRReviewDemo.snapshot()
        snapshot.review.headSHA = "synthetic-new-head"
        store.receive(snapshot); session.configure(store: store)
        #expect(session.isStale)
        #expect(session.plan == original)
        #expect(!session.canAsk)
        #expect(!session.canAdvance)
        session.start(); await settle(session)
        #expect(!session.isStale)
        #expect(session.plan?.headSHA == "synthetic-new-head")
    }

    @Test("Saved earlier-revision answers stay readable without navigating current code")
    func earlierAnswerDoesNotRetargetCurrentPatch() async throws {
        let (store, session) = configured()
        session.start(); await settle(session)
        session.beginQuestion(); session.draft = "Why was the migration removed?"
        session.submitQuestion(); await settle(session)
        let earlierAnswer = try #require(session.transcript.first)
        var snapshot = PRReviewDemo.snapshot()
        snapshot.review.headSHA = "synthetic-refreshed-head"
        store.receive(snapshot); session.configure(store: store)
        session.start(); await settle(session)
        #expect(!session.isStale)
        let currentPath = store.selectedPath
        session.showAnswer(earlierAnswer)
        #expect(session.isStale)
        #expect(session.answer == earlierAnswer.answer)
        #expect(store.selectedPath == currentPath)
        #expect(!session.canAsk)
        #expect(!session.canAdvance)
        session.togglePlayback()
        #expect(!session.isPlaying)
        session.returnToWalkthrough()
        #expect(!session.isStale)
        #expect(session.canAsk)
        #expect(session.plan?.headSHA == "synthetic-refreshed-head")
        #expect(store.selectedPath == currentPath)
    }

    @Test("Late generation from another host is discarded")
    func hostChangeRejectsLateGeneration() async {
        let (store, session) = configured()
        session.start()
        store.configure(client: nil, machineID: "another-synthetic-host", demo: true)
        store.receive(PRReviewDemo.snapshot()); session.configure(store: store)
        await Task.yield(); await Task.yield()
        #expect(session.plan == nil)
        #expect(!session.isBusy)
        #expect(session.scope?.machineID == "another-synthetic-host")
    }

    @Test("Progress and answers reopen paused in the same host and code revision")
    func restoresPausedProgress() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guide-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, session) = configured(persistenceURL: url)
        session.start(); await settle(session); session.advance()
        session.beginQuestion(); session.draft = "Show the source"
        session.submitQuestion(); await settle(session)
        session.pause()
        let restored = PRReviewGuideSession(persistenceURL: url)
        restored.configure(store: store)
        #expect(restored.chapterIndex == 1)
        #expect(restored.transcript.count == 1)
        #expect(!restored.isPlaying)
        #expect(!restored.isDetour)
    }

    @Test("Demo isolation neither restores nor overwrites persisted operator progress")
    func demoPersistenceIsolation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guide-isolation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, savedSession) = configured(persistenceURL: url)
        savedSession.start(); await settle(savedSession); savedSession.advance()
        let savedBytes = try Data(contentsOf: url)

        let demo = PRReviewGuideSession(persistenceURL: url, allowsDemoPersistence: false)
        demo.configure(store: store)
        #expect(demo.plan == nil)
        demo.start(); await settle(demo); demo.advance(); demo.advance(); demo.pause()
        #expect(try Data(contentsOf: url) == savedBytes)

        let explicitlyRestored = PRReviewGuideSession(persistenceURL: url)
        explicitlyRestored.configure(store: store)
        #expect(explicitlyRestored.chapterIndex == 1)
    }

    @Test("Guide selections retain mixed before and after spans in request JSON")
    func selectionWireContract() throws {
        let request = PRReviewGuideRequest(requestID: "synthetic-request", baseSHA: "base", headSHA: "head", kind: "answer", question: "Why?", path: "Sources/Catalog.swift", chapterID: nil, continueFromGuideID: nil, selection: .init(text: "old\nnew", spans: [.init(side: "old", startLine: 4, endLine: 5), .init(side: "new", startLine: 4, endLine: 7)]))
        let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(value["request_id"] as? String == "synthetic-request")
        let selection = try #require(value["selection"] as? [String: Any])
        let spans = try #require(selection["spans"] as? [[String: Any]])
        #expect(spans.map { $0["side"] as? String } == ["old", "new"])
        #expect(spans[1]["endLine"] as? Int == 7)
    }
}
