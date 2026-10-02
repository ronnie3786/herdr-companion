import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review agent operations")
@MainActor
struct PRReviewAgentStoreTests {
    enum ScopeChange: String, CaseIterable, Sendable {
        case host, reconnect, selection
    }

    @Test("Late agent creation success and failure preserve the current scope", arguments: ScopeChange.allCases, [false, true])
    func lateCreate(change: ScopeChange, fails: Bool) async throws {
        let gate = SyntheticPRReviewGate()
        var created = PRReviewDemo.snapshot()
        created.review.id = "prr_created"
        let response = created
        let client = AgentOperationTestClient(create: { _, _ in
            await gate.wait()
            if fails { throw APIError.server(status: 503, message: "Stale creation failed") }
            return response
        })
        let store = try makeStore(client)
        let request = Task { await store.createWithAgents(url: "https://github.com/example/sample/pull/1", agentIDs: ["pr-review-comprehensive"]) }
        await gate.waitUntilWaiting()
        changeScope(store, change: change)
        let expectedReview = store.selectedReviewID
        let expectedMachine = store.currentMachineID
        store.error = "Current scope notice"
        await gate.release()
        #expect(await request.value == false)
        #expect(store.currentMachineID == expectedMachine)
        #expect(store.selectedReviewID == expectedReview)
        #expect(store.snapshot?.review.id == expectedReview)
        #expect(store.error == "Current scope notice")
        #expect(!store.isCreating)
    }

    @Test("Late reviewer queue success and failure preserve the current scope", arguments: ScopeChange.allCases, [false, true])
    func lateQueue(change: ScopeChange, fails: Bool) async throws {
        let gate = SyntheticPRReviewGate()
        let client = AgentOperationTestClient(queue: { _, _ in
            await gate.wait()
            if fails { throw APIError.server(status: 503, message: "Stale queue failed") }
            return []
        })
        let store = try makeStore(client)
        let request = Task { await store.queueAgents(["pr-review-comprehensive"]) }
        await gate.waitUntilWaiting()
        changeScope(store, change: change)
        let expectedReview = store.selectedReviewID
        store.error = "Current scope notice"
        await gate.release()
        #expect(await request.value == false)
        #expect(store.selectedReviewID == expectedReview)
        #expect(store.snapshot?.review.id == expectedReview)
        #expect(store.error == "Current scope notice")
        #expect(!store.isQueueingAgents)
        #expect(await client.calls.count("review") == 0)
    }

    @Test("A connection or selection change during the queue refresh cannot report completion", arguments: ScopeChange.allCases)
    func lateQueueRefresh(change: ScopeChange) async throws {
        let gate = SyntheticPRReviewGate()
        let client = AgentOperationTestClient(review: { _ in
            await gate.wait()
            return PRReviewDemo.snapshot()
        })
        let store = try makeStore(client)
        let request = Task { await store.queueAgents(["pr-review-comprehensive"]) }
        await gate.waitUntilWaiting()
        changeScope(store, change: change)
        let expectedReview = store.selectedReviewID
        await gate.release()
        #expect(await request.value == false)
        #expect(store.selectedReviewID == expectedReview)
        #expect(store.snapshot?.review.id == expectedReview)
        #expect(!store.isQueueingAgents)
    }

    @Test("Duplicate submissions wait for the in-flight queue and creation")
    func duplicateRequests() async throws {
        let queueGate = SyntheticPRReviewGate()
        let queueClient = AgentOperationTestClient(queue: { _, _ in await queueGate.wait(); return [] })
        let store = try makeStore(queueClient)
        let firstQueue = Task { await store.queueAgents(["pr-review-comprehensive"]) }
        await queueGate.waitUntilWaiting()
        #expect(store.isQueueingAgents)
        #expect(await store.queueAgents(["pr-review-comprehensive"]) == false)
        #expect(await queueClient.calls.count("queue") == 1)
        await queueGate.release()
        #expect(await firstQueue.value)
        #expect(!store.isQueueingAgents)

        let createGate = SyntheticPRReviewGate()
        let createClient = AgentOperationTestClient(create: { _, _ in await createGate.wait(); return PRReviewDemo.snapshot() })
        let creatingStore = try makeStore(createClient)
        let firstCreate = Task { await creatingStore.createWithAgents(url: "https://github.com/example/sample/pull/1", agentIDs: []) }
        await createGate.waitUntilWaiting()
        #expect(creatingStore.isCreating)
        #expect(await creatingStore.createWithAgents(url: "https://github.com/example/sample/pull/1", agentIDs: []) == false)
        #expect(await createClient.calls.count("create") == 1)
        await createGate.release()
        #expect(await firstCreate.value)
        #expect(!creatingStore.isCreating)
    }

    @Test("Legacy companions never receive the new agent endpoints")
    func missingCapability() async throws {
        let client = AgentOperationTestClient()
        let store = try makeStore(client)
        store.capabilities = nil
        #expect(await store.createWithAgents(url: "https://github.com/example/sample/pull/1", agentIDs: ["pr-review-comprehensive"]) == false)
        #expect(await store.queueAgents(["pr-review-comprehensive"]) == false)
        #expect(await client.calls.count("create") == 0)
        #expect(await client.calls.count("queue") == 0)
        #expect(!store.isCreating && !store.isQueueingAgents)
    }

    @Test("Current queue failures retain a retryable error")
    func queueFailure() async throws {
        let client = AgentOperationTestClient(queue: { _, _ in
            throw APIError.server(status: 503, message: "Synthetic queue unavailable")
        })
        let store = try makeStore(client)
        #expect(await store.queueAgents(["pr-review-comprehensive"]) == false)
        #expect(store.error?.contains("Synthetic queue unavailable") == true)
        #expect(!store.isQueueingAgents)
    }

    @Test("Late linked-report responses are cancelled for changed scopes", arguments: ScopeChange.allCases, [false, true])
    func lateLinkedDocument(change: ScopeChange, fails: Bool) async throws {
        let gate = SyntheticPRReviewGate()
        let report = PRReviewDemo.snapshot().documents[0]
        let client = AgentOperationTestClient(document: { _, _ in
            await gate.wait()
            if fails { throw APIError.server(status: 503, message: "Stale report lookup failed") }
            return report
        })
        let store = try makeStore(client)
        store.snapshot?.documents = []
        let request = Task {
            do {
                _ = try await store.linkedReportDocument(id: report.id, reviewID: report.reviewID)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        await gate.waitUntilWaiting()
        changeScope(store, change: change)
        await gate.release()
        #expect(await request.value)
        #expect(store.error == nil)
    }

    @Test("Linked reports use the current cache and validate remote identity")
    func linkedDocumentIdentity() async throws {
        let report = PRReviewDemo.snapshot().documents[0]
        let client = AgentOperationTestClient(document: { _, _ in report })
        let store = try makeStore(client)
        #expect(try await store.linkedReportDocument(id: report.id, reviewID: report.reviewID) == report)
        #expect(await client.calls.count("document") == 0)
        store.snapshot?.documents = []
        #expect(try await store.linkedReportDocument(id: report.id, reviewID: report.reviewID) == report)
        #expect(await client.calls.count("document") == 1)
        await #expect(throws: (any Error).self) {
            _ = try await store.linkedReportDocument(id: "prdoc_other", reviewID: report.reviewID)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.linkedReportDocument(id: report.id, reviewID: "prr_other")
        }
        #expect(await client.calls.count("document") == 2)
    }

    private func makeStore(_ client: AgentOperationTestClient) throws -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: client, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data("""
            {"ok":true,"capabilities":["pr-review-v1","pr-review-agents-v1"],"available":true,"skills":[]}
            """.utf8))
        return store
    }

    private func changeScope(_ store: PRReviewStore, change: ScopeChange) {
        switch change {
        case .host:
            store.configure(client: AgentOperationTestClient(), machineID: "host-b", demo: false)
            store.select(PRReviewDemo.secondReviewID)
            store.receive(PRReviewDemo.snapshot(for: PRReviewDemo.secondReviewID))
        case .reconnect:
            store.reconnect(client: AgentOperationTestClient(), machineID: "host-a", demo: false)
        case .selection:
            store.select(PRReviewDemo.secondReviewID)
            store.receive(PRReviewDemo.snapshot(for: PRReviewDemo.secondReviewID))
        }
    }
}

private actor AgentOperationCallCounts {
    private var values: [String: Int] = [:]
    func record(_ name: String) { values[name, default: 0] += 1 }
    func count(_ name: String) -> Int { values[name, default: 0] }
}

/// Uses the shared client for unrelated endpoints and gates only the new operations.
private struct AgentOperationTestClient: PRReviewClient {
    let calls = AgentOperationCallCounts()
    let base = TestPRReviewClient()
    var create: @Sendable (String, [String]) async throws -> PRReviewSnapshot = { _, _ in PRReviewDemo.snapshot() }
    var queue: @Sendable (String, [String]) async throws -> [PRReviewRun] = { _, _ in [] }
    var review: @Sendable (String) async throws -> PRReviewSnapshot = { PRReviewDemo.snapshot(for: $0) }
    var document: @Sendable (String, String) async throws -> PRReviewDocument = { _, _ in throw APIError.invalidResponse }

    func createPRReview(url: String, agentIDs: [String], requestID: String) async throws -> PRReviewSnapshot {
        await calls.record("create")
        return try await create(url, agentIDs)
    }
    func createPRReviewAgentRuns(id: String, agentIDs: [String], requestID: String) async throws -> [PRReviewRun] {
        await calls.record("queue")
        return try await queue(id, agentIDs)
    }
    func prReview(id: String) async throws -> PRReviewSnapshot {
        await calls.record("review")
        return try await review(id)
    }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument {
        await calls.record("document")
        return try await document(reviewID, documentID)
    }
    func prReviewCapabilities() async throws -> PRReviewCapabilities { try await base.prReviewCapabilities() }
    func prReviewSkills() async throws -> [PRReviewSkill] { try await base.prReviewSkills() }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { try await base.addPRReviewSkill(body) }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { try await base.removePRReviewSkill(id: id, requestID: requestID) }
    func prReviews(scope: String) async throws -> [PRReviewSummary] { try await base.prReviews(scope: scope) }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot { try await base.createPRReview(url: url, skillIDs: skillIDs, requestID: requestID) }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot { try await base.refreshPRReview(id: id, requestID: requestID) }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot { try await base.archivePRReview(id: id, archived: archived, requestID: requestID) }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { try await base.prReviewDiff(id: id, path: path) }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText { try await base.prReviewFileText(id: id, path: path, side: side, start: start, end: end) }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { try await base.prReviewFindings(id: id, path: path) }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun { try await base.createPRReviewRun(id: id, skillID: skillID, requestID: requestID) }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { try await base.prReviewRun(reviewID: reviewID, runID: runID) }
    func finishPRReviewRun(reviewID: String, runID: String, state: PRReviewRunState, note: String?, requestID: String) async throws -> PRReviewRun { try await base.finishPRReviewRun(reviewID: reviewID, runID: runID, state: state, note: note, requestID: requestID) }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { try await base.prReviewRunOutput(reviewID: reviewID, runID: runID, lines: lines) }
    func markPRReviewSkill(reviewID: String, skillID: String, state: String, note: String?, requestID: String) async throws -> PRReviewSkillState { try await base.markPRReviewSkill(reviewID: reviewID, skillID: skillID, state: state, note: note, requestID: requestID) }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary { try await base.rankPRReview(id: id, requestID: requestID) }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { try await base.setPRReviewRankings(id: id, files: files, requestID: requestID) }
    func setPRReviewViewed(id: String, paths: [String], viewed: Bool, requestID: String) async throws -> [PRReviewFile] { try await base.setPRReviewViewed(id: id, paths: paths, viewed: viewed, requestID: requestID) }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { try await base.syncPRReviewViewed(id: id, requestID: requestID) }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { try await base.prReviewDocuments(id: id) }
    func addPRReviewDocument(id: String, payload: PRReviewDocumentPayload, requestID: String) async throws -> PRReviewDocument { try await base.addPRReviewDocument(id: id, payload: payload, requestID: requestID) }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws { try await base.downloadPRReviewDocument(reviewID: reviewID, documentID: documentID, expectedByteSize: expectedByteSize, to: destinationURL) }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { try await base.prReviewEvents(id: id, after: after) }
}
