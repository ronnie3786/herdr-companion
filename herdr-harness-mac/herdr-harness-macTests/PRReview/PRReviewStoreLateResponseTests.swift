import Foundation
import Testing
@testable import herdr_harness_mac

/// Late-response coverage for every PR Review store operation that publishes
/// state after an `await`. A reconnect or invalidation changes the connection
/// generation, so the stale completion must be discarded locally while the
/// server operation it already sent is preserved.
@MainActor
@Suite("PR Review late responses", .serialized)
struct PRReviewStoreLateResponseTests {
    @Test("A delayed viewed response cannot overwrite a newer snapshot after reconnect")
    func lateViewedResponseIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.setViewed = { _, _, _ in
            await gate.wait()
            var files = PRReviewDemo.snapshot().files
            files[0].viewed = true
            files[1].viewed = false
            return files
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        let firstPath = try #require(store.snapshot?.files.first?.path)

        let request = Task { await store.setViewed(paths: [firstPath], viewed: true) }
        await gate.waitUntilWaiting()

        // The same review is reconnected and its newer server state is loaded
        // before the old response arrives.
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)
        var newer = PRReviewDemo.snapshot()
        newer.review.revision += 1
        newer.files[0].viewed = false
        newer.files[1].viewed = true
        store.receive(newer)

        await gate.release()
        await request.value

        #expect(store.snapshot?.files[0].viewed == false)
        #expect(store.snapshot?.files[1].viewed == true)
        #expect(await counter.count("set-viewed") == 1)
    }

    @Test("A delayed sync response cannot replace files after reconnect")
    func lateSyncViewedResponseIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.syncViewed = { _ in
            await gate.wait()
            var files = PRReviewDemo.snapshot().files
            files[0].viewed = true
            files[1].viewed = false
            return files
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let request = Task { await store.syncViewed() }
        await gate.waitUntilWaiting()

        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)
        var newer = PRReviewDemo.snapshot()
        newer.review.revision += 1
        newer.files[0].viewed = false
        newer.files[1].viewed = true
        store.receive(newer)

        await gate.release()
        await request.value

        #expect(store.snapshot?.files[0].viewed == false)
        #expect(store.snapshot?.files[1].viewed == true)
        #expect(await counter.count("sync-viewed") == 1)
    }

    @Test("A delayed refresh error cannot publish onto a reconnected store")
    func lateRefreshErrorIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.refresh = { _ in
            await gate.wait()
            throw APIError.server(status: 500, message: "synthetic stale refresh failure")
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let request = Task { await store.refreshReview() }
        await gate.waitUntilWaiting()
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)

        await gate.release()
        await request.value

        #expect(store.error == nil)
        #expect(store.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(await counter.count("refresh-review") == 1)
    }

    @Test("A delayed archive response cannot archive a reconnected store")
    func lateArchiveResponseIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.archive = { id, archived in
            await gate.wait()
            var snapshot = PRReviewDemo.snapshot(for: id)
            snapshot.review.revision += 1
            if archived {
                snapshot.review.archivedAt = "2026-01-15T14:30:00Z"
            }
            return snapshot
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let request = Task { await store.archive(true) }
        await gate.waitUntilWaiting()
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)

        await gate.release()
        await request.value

        #expect(store.snapshot?.review.archivedAt == nil)
        #expect(!store.archivedReviews.contains(where: { $0.id == PRReviewDemo.reviewID }))
        #expect(await counter.count("archive") == 1)
    }

    @Test("A delayed create cannot install a review on a reconnected store")
    func lateCreateResponseIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.create = { _, _ in
            await gate.wait()
            var snapshot = PRReviewDemo.snapshot()
            snapshot.review.id = "prr_stale_created"
            return snapshot
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let request = Task { await store.create(url: "https://example.invalid/fictional/pull/1") }
        await gate.waitUntilWaiting()
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)

        await gate.release()
        await request.value

        #expect(store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(!store.reviews.contains(where: { $0.id == "prr_stale_created" }))
        #expect(await counter.count("create") == 1)
    }

    @Test("A delayed upload completion cannot publish a document after reconnect")
    func lateUploadResponseIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let oldClient = LateResponseClient(counter: counter)
        oldClient.addDocument = { _ in
            await gate.wait()
            var document = PRReviewDemo.snapshot().documents[0]
            document.id = "prdoc_stale_upload"
            document.contentHash = "stale-upload"
            return document
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        let documentCount = store.snapshot?.documents.count ?? 0

        let file = FileManager.default.temporaryDirectory
            .appending(path: "PRReviewLateResponse-\(UUID().uuidString).md")
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = Task { await store.uploadDocuments(urls: [file]) }
        await gate.waitUntilWaiting()
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)

        await gate.release()
        await request.value

        #expect(store.snapshot?.documents.count == documentCount)
        #expect(store.snapshot?.documents.contains(where: { $0.id == "prdoc_stale_upload" }) == false)
        // A reconnect must settle an interrupted upload into a terminal state
        // that still offers Retry instead of leaving the row spinning forever.
        let status = try #require(store.documentUploads.values.first?.status)
        guard case let .failed(message) = status else {
            Issue.record("an upload interrupted by reconnect must become retryable, got \(status)")
            return
        }
        #expect(!message.isEmpty)
        #expect(store.contextImportError == nil)
        #expect(await counter.count("add-document") == 1)
    }

    @Test("An interrupted upload retries through the new transport after reconnect")
    func interruptedUploadRetriesAfterReconnect() async throws {
        let gate = LateResponseGate()
        let oldCounter = MethodCounter()
        let newCounter = MethodCounter()
        let oldClient = LateResponseClient(counter: oldCounter)
        oldClient.addDocument = { _ in
            await gate.wait()
            return PRReviewDemo.snapshot().documents[0]
        }
        let newClient = LateResponseClient(counter: newCounter)
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let file = FileManager.default.temporaryDirectory
            .appending(path: "PRReviewLateResponse-\(UUID().uuidString).md")
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = Task { await store.uploadDocuments(urls: [file]) }
        await gate.waitUntilWaiting()
        store.reconnect(client: newClient, machineID: "host-a", demo: false)

        let settled = try #require(store.documentUploads.values.first?.status)
        guard case .failed = settled else {
            Issue.record("reconnect must settle the upload before its stale completion, got \(settled)")
            return
        }

        await gate.release()
        await request.value

        // The stale completion belongs to the old generation and must not
        // overwrite the settled state.
        #expect(store.documentUploads.values.first?.status == settled)

        // Retry reuses the upload row and goes through the reconnected client.
        await store.uploadDocuments(urls: [file])
        #expect(store.documentUploads.values.first?.status == .uploaded)
        #expect(await newCounter.count("add-document") == 1)
        #expect(await oldCounter.count("add-document") == 1)
    }

    @Test("An invalidated connection settles an in-flight upload into a retryable state")
    func invalidatedUploadSettlesAndRetries() async throws {
        let gate = LateResponseGate()
        let oldCounter = MethodCounter()
        let newCounter = MethodCounter()
        let oldClient = LateResponseClient(counter: oldCounter)
        oldClient.addDocument = { _ in
            await gate.wait()
            return PRReviewDemo.snapshot().documents[0]
        }
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let file = FileManager.default.temporaryDirectory
            .appending(path: "PRReviewLateResponse-\(UUID().uuidString).md")
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = Task { await store.uploadDocuments(urls: [file]) }
        await gate.waitUntilWaiting()
        store.invalidateConnection()

        // Invalidation retires the uploading row into a terminal state that
        // still offers Retry rather than leaving the Context row spinning.
        let settled = try #require(store.documentUploads.values.first?.status)
        guard case let .failed(message) = settled else {
            Issue.record("an upload interrupted by invalidation must become retryable, got \(settled)")
            return
        }
        #expect(!message.isEmpty)
        #expect(store.contextImportError == nil)
        #expect(store.documentTransport(for: PRReviewDemo.snapshot().documents[0]) == nil)

        await gate.release()
        await request.value
        #expect(store.documentUploads.values.first?.status == settled)

        // Retry waits for a transport. Once a host returns, it uploads through
        // the new client without resending from the previous generation.
        let newClient = LateResponseClient(counter: newCounter)
        store.reconnect(client: newClient, machineID: "host-a", demo: false)
        await store.uploadDocuments(urls: [file])
        #expect(store.documentUploads.values.first?.status == .uploaded)
        #expect(await newCounter.count("add-document") == 1)
        #expect(await oldCounter.count("add-document") == 1)
    }

    @Test("An upload that completes after the reviewer switches reviews still settles")
    func uploadSettlesAcrossSelectionChange() async throws {
        let gate = LateResponseGate()
        let client = LateResponseClient()
        client.addDocument = { _ in
            await gate.wait()
            return PRReviewDemo.snapshot().documents[0]
        }
        let store = PRReviewStore()
        store.configure(client: client, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let file = FileManager.default.temporaryDirectory
            .appending(path: "PRReviewLateResponse-\(UUID().uuidString).md")
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = Task { await store.uploadDocuments(urls: [file]) }
        await gate.waitUntilWaiting()
        // The completion belongs to the same connection but a different
        // review; its row must still settle instead of spinning forever.
        store.select(PRReviewDemo.secondReviewID)
        await gate.release()
        await request.value

        #expect(store.documentUploads.values.first?.status == .uploaded)
        #expect(store.snapshot == nil)
    }

    @Test("A refreshed document list reconciles an interrupted upload to uploaded")
    func refreshedDocumentsReconcileInterruptedUpload() async throws {
        let gate = LateResponseGate()
        let client = LateResponseClient()
        client.addDocument = { _ in
            await gate.wait()
            return PRReviewDemo.snapshot().documents[0]
        }
        let store = PRReviewStore()
        store.configure(client: client, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())

        let file = FileManager.default.temporaryDirectory
            .appending(path: "PRReviewLateResponse-\(UUID().uuidString).md")
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let request = Task { await store.uploadDocuments(urls: [file]) }
        await gate.waitUntilWaiting()
        store.reconnect(client: LateResponseClient(), machineID: "host-a", demo: false)
        await gate.release()
        await request.value

        guard case .failed = try #require(store.documentUploads.values.first?.status) else {
            Issue.record("the interrupted upload should be settled before reconciliation")
            return
        }

        // The server did receive the document before the transport changed,
        // so the refresh lists it and retires the Retry affordance without
        // resending any mutation.
        var refreshed = PRReviewDemo.snapshot()
        refreshed.review.revision += 1
        var document = PRReviewDemo.snapshot().documents[0]
        document.id = "prdoc_reconciled_upload"
        document.filename = file.lastPathComponent
        document.origin = "user"
        refreshed.documents.append(document)
        store.receive(refreshed)

        #expect(store.documentUploads.values.first?.status == .uploaded)
    }

    @Test("A delayed download cannot publish a ready phase after invalidation")
    func lateDownloadCompletionIsRejected() async throws {
        let gate = LateResponseGate()
        let counter = MethodCounter()
        let client = LateResponseClient(counter: counter)
        client.download = { _, _, destination in
            await gate.wait()
            try Data("synthetic stale report".utf8).write(to: destination, options: .atomic)
        }
        let cache = PRReviewDocumentCache(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "PRReviewLateResponse-\(UUID().uuidString)")
        )
        let store = PRReviewStore(documentCache: cache)
        store.configure(client: client, machineID: "host-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        let document = PRReviewDemo.snapshot().documents[0]

        let request = Task { () -> Bool in
            do {
                _ = try await store.localURL(for: document)
                return false
            } catch {
                return HerdrCancellation.isCancellation(error)
            }
        }
        await gate.waitUntilWaiting()
        store.invalidateConnection()

        await gate.release()
        let wasCancelled = await request.value

        #expect(wasCancelled)
        // The interrupted download settles into a terminal, retryable state
        // rather than leaving the Context row downloading forever.
        let phase = try #require(store.documentPhases[document.id])
        guard case .failed = phase else {
            Issue.record("an invalidated download must settle, got \(phase)")
            return
        }
        #expect(await counter.count("download") == 1)
    }
}

/// A request gate that lets a test reconnect a store while a response is held.
private actor LateResponseGate {
    private var isWaiting = false
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isWaiting = true
        let arrivals = arrivalContinuations
        arrivalContinuations.removeAll()
        arrivals.forEach { $0.resume() }
        await withCheckedContinuation { responseContinuation = $0 }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { arrivalContinuations.append($0) }
    }

    func release() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}

private actor MethodCounter {
    private var counts: [String: Int] = [:]

    func record(_ method: String) {
        counts[method, default: 0] += 1
    }

    func count(_ method: String) -> Int {
        counts[method] ?? 0
    }
}

/// A PR Review client whose methods can be gated by a handler, so a test can
/// hold one response while the store reconnects underneath it.
private final class LateResponseClient: PRReviewClient, @unchecked Sendable {
    let counter: MethodCounter
    var setViewed: (@Sendable (String, [String], Bool) async throws -> [PRReviewFile])?
    var syncViewed: (@Sendable (String) async throws -> [PRReviewFile])?
    var create: (@Sendable (String, [String]) async throws -> PRReviewSnapshot)?
    var refresh: (@Sendable (String) async throws -> PRReviewSnapshot)?
    var archive: (@Sendable (String, Bool) async throws -> PRReviewSnapshot)?
    var addDocument: (@Sendable (String) async throws -> PRReviewDocument)?
    var download: (@Sendable (String, String, URL) async throws -> Void)?

    init(counter: MethodCounter = MethodCounter()) {
        self.counter = counter
    }

    func prReviewCapabilities() async throws -> PRReviewCapabilities {
        try decode("{\"ok\":true,\"capabilities\":[\"pr-review-v1\"],\"available\":true,\"skills\":[]}")
    }

    func prReviewSkills() async throws -> [PRReviewSkill] { [] }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill {
        PRReviewDemo.snapshot().skills[0].skill
    }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { [] }
    func prReviews(scope: String) async throws -> [PRReviewSummary] {
        scope == "archived" ? PRReviewDemo.archivedReviews() : PRReviewDemo.reviews()
    }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot {
        await counter.record("create")
        if let create { return try await create(url, skillIDs) }
        return PRReviewDemo.snapshot()
    }
    func prReview(id: String) async throws -> PRReviewSnapshot { PRReviewDemo.snapshot(for: id) }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot {
        await counter.record("refresh-review")
        if let refresh { return try await refresh(id) }
        return PRReviewDemo.snapshot(for: id)
    }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot {
        await counter.record("archive")
        if let archive { return try await archive(id, archived) }
        return PRReviewDemo.snapshot(for: id)
    }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { PRReviewDemo.diff(for: id) }
    func prReviewFileText(
        id: String,
        path: String,
        side: PRReviewSide,
        start: Int?,
        end: Int?
    ) async throws -> PRReviewFileText { throw APIError.invalidResponse }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings {
        throw APIError.invalidResponse
    }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun {
        throw APIError.invalidResponse
    }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun {
        throw APIError.invalidResponse
    }
    func finishPRReviewRun(
        reviewID: String,
        runID: String,
        state: PRReviewRunState,
        note: String?,
        requestID: String
    ) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { "" }
    func markPRReviewSkill(
        reviewID: String,
        skillID: String,
        state: String,
        note: String?,
        requestID: String
    ) async throws -> PRReviewSkillState { PRReviewDemo.snapshot().skills[0] }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary {
        PRReviewDemo.snapshot(for: id).review
    }
    func setPRReviewRankings(
        id: String,
        files: [[String: String]],
        requestID: String
    ) async throws -> [PRReviewFile] { [] }
    func setPRReviewViewed(
        id: String,
        paths: [String],
        viewed: Bool,
        requestID: String
    ) async throws -> [PRReviewFile] {
        await counter.record("set-viewed")
        if let setViewed { return try await setViewed(id, paths, viewed) }
        return PRReviewDemo.snapshot(for: id).files
    }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] {
        await counter.record("sync-viewed")
        if let syncViewed { return try await syncViewed(id) }
        return []
    }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { [] }
    func addPRReviewDocument(
        id: String,
        payload: PRReviewDocumentPayload,
        requestID: String
    ) async throws -> PRReviewDocument {
        await counter.record("add-document")
        if let addDocument { return try await addDocument(id) }
        return PRReviewDemo.snapshot().documents[0]
    }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument {
        throw APIError.invalidResponse
    }
    func downloadPRReviewDocument(
        reviewID: String,
        documentID: String,
        expectedByteSize: Int64,
        to destinationURL: URL
    ) async throws {
        await counter.record("download")
        if let download {
            try await download(reviewID, documentID, destinationURL)
            return
        }
        throw APIError.invalidResponse
    }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { [] }

    private func decode<T: Decodable>(_ string: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(string.utf8))
    }
}
