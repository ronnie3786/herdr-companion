import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review store", .timeLimit(.minutes(1)))
struct PRReviewStoreTests {
    @Test("Configure resets state and seeds the synthetic demo")
    func configureResetsAndSeedsDemo() async {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        await store.refresh()

        #expect(store.reviews.map(\.id) == [PRReviewDemo.reviewID, PRReviewDemo.secondReviewID])
        #expect(store.archivedReviews.count == 1)
        #expect(store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(store.snapshot?.review.id == PRReviewDemo.reviewID)
    }

    @Test("Demo refresh and diff lookup follow the selected review")
    func demoLookupIsReviewAware() async {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.select(PRReviewDemo.secondReviewID)
        await store.refresh()

        #expect(store.snapshot?.review.id == PRReviewDemo.secondReviewID)
        #expect(store.snapshot?.review.title == PRReviewDemo.snapshot(for: PRReviewDemo.secondReviewID).review.title)
        #expect(store.snapshot?.files.map(\.path) == PRReviewDemo.snapshot(for: PRReviewDemo.secondReviewID).files.map(\.path))
        let path = store.orderedFiles.first?.path
        store.selectedPath = path
        await store.loadDiff(for: path)

        #expect(store.diff?.reviewID == PRReviewDemo.secondReviewID)
        #expect(store.diff?.files.first?.path == path)
        #expect(store.diff != PRReviewDemo.diff())
    }

    @Test("Default demo fixtures still describe the first review")
    func defaultDemoFixturesAreUnchanged() {
        #expect(PRReviewDemo.snapshot().review.id == PRReviewDemo.reviewID)
        #expect(PRReviewDemo.diff().reviewID == PRReviewDemo.reviewID)
        #expect(PRReviewDemo.snapshot(for: "unknowable").review.id == PRReviewDemo.reviewID)
        #expect(PRReviewDemo.diff(for: "unknowable").reviewID == PRReviewDemo.reviewID)
        #expect(PRReviewDemo.reviews().count == 2)
    }

    @Test("A late refresh cannot overwrite a newer configuration")
    func refreshGenerationGuardDropsLateResponse() async throws {
        let store = PRReviewStore()
        store.configure(client: TestPRReviewClient(delay: .milliseconds(30)), machineID: "one", demo: false)

        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(2))
        store.configure(client: nil, machineID: "demo", demo: true)
        await refresh.value

        #expect(store.isDemo)
        #expect(store.reviews.first?.id == PRReviewDemo.reviewID)
    }

    @Test("A 404 companion is marked unsupported")
    func unsupportedServerIsReported() async {
        let store = PRReviewStore()
        store.configure(
            client: TestPRReviewClient(capabilitiesError: .server(status: 404, message: "missing")),
            machineID: "one",
            demo: false
        )

        await store.refresh()

        #expect(store.unsupported)
    }

    @Test("An older review revision is rejected")
    func staleRevisionIsRejected() {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)

        var newer = PRReviewDemo.snapshot()
        newer.review.revision = 4
        store.receive(newer)

        var stale = PRReviewDemo.snapshot()
        stale.review.revision = 3
        stale.review.title = "Stale title"
        store.receive(stale)

        #expect(store.snapshot?.review.revision == 4)
        #expect(store.snapshot?.review.title != "Stale title")
    }

    @Test("File ordering and filters are applied locally")
    func orderedFilesSupportsModesAndFilters() async {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        await store.refresh()

        var snapshot = PRReviewDemo.snapshot()
        snapshot.files[0].guidedOrder = 2
        snapshot.files[1].guidedOrder = 1
        store.receive(snapshot)

        let githubOrder = store.orderedFiles.map(\.path)
        store.viewMode = .guided
        let guidedOrder = store.orderedFiles.map(\.path)
        store.impactFilter = .high
        let highImpact = store.orderedFiles
        store.hideViewed = true
        let unviewedHighImpact = store.orderedFiles
        store.impactFilter = .all
        store.search = "SyncClient"

        #expect(githubOrder != guidedOrder)
        #expect(guidedOrder.first == "Sources/Catalog/SyncClient.swift")
        #expect(highImpact.allSatisfy { $0.impact == .high })
        #expect(unviewedHighImpact.allSatisfy { !$0.viewed })
        store.search = "Sources/Catalog/SyncClient.swift"
        #expect(store.orderedFiles.map(\.path) == ["Sources/Catalog/SyncClient.swift"])
    }

    @Test("Setting viewed updates immediately before the request finishes")
    func setViewedIsOptimistic() async {
        let client = TestPRReviewClient(delay: .milliseconds(40))
        let store = PRReviewStore()
        store.configure(client: client, machineID: "one", demo: false)
        store.receive(PRReviewDemo.snapshot())
        let path = try! #require(store.snapshot?.files.first?.path)

        let request = Task { await store.setViewed(paths: [path], viewed: true) }
        await Task.yield()

        #expect(store.snapshot?.files.first?.viewed == true)
        await request.value
    }

    @Test("Non-capability 404s stay ordinary errors and clear after a successful refresh")
    func nonCapability404DoesNotMarkUnsupported() async {
        let store = PRReviewStore()
        let client = TestPRReviewClient(reviewError: .server(status: 404, message: "fictional missing review"))
        store.configure(client: client, machineID: "one", demo: false)
        store.select(PRReviewDemo.reviewID)

        await store.refreshSelected()

        #expect(!store.unsupported)
        #expect(store.error != nil)
    }

    @Test("Failed initial refresh finishes loading and retry recovers")
    func initialRefreshFailureCanRecover() async {
        let store = PRReviewStore()
        let client = TestPRReviewClient(capabilitiesError: .invalidResponse)
        store.configure(client: client, machineID: "one", demo: false)

        await store.refresh()

        #expect(store.hasLoaded)
        #expect(store.error != nil)
    }

    @Test("Receive inserts unknown active and archived reviews into their lists")
    func receiveInsertsUnknownReviews() {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.select(nil)
        var active = PRReviewDemo.snapshot()
        active.review.id = "prr_fictional_active"
        active.review.archivedAt = nil
        store.receive(active)
        store.select(nil)
        var archived = PRReviewDemo.snapshot()
        archived.review.id = "prr_fictional_archived"
        archived.review.archivedAt = "2026-01-15T14:30:00Z"
        store.receive(archived)

        #expect(store.reviews.contains(where: { $0.id == active.review.id }))
        #expect(store.archivedReviews.contains(where: { $0.id == archived.review.id }))
    }

    @Test("Create selects its newly returned review")
    func createSelectsNewReview() async {
        let store = PRReviewStore()
        let client = TestPRReviewClient(createdReviewID: "prr_fictional_new")
        store.configure(client: client, machineID: "one", demo: false)
        store.select(PRReviewDemo.reviewID)

        await store.create(url: "https://example.invalid/fictional/pull/7")

        #expect(store.selectedReviewID == "prr_fictional_new")
    }

    @Test("A late diff from another host cannot replace the current host diff")
    func diffGenerationGuardDropsLateHostResponse() async {
        let gate = DiffResponseGate()
        let oldClient = TestPRReviewClient(diffHandler: { _, _ in
            await gate.wait()
            var diff = PRReviewDemo.diff()
            diff.files[0].hunks[0].lines[1].text = "stale host code"
            return diff
        })
        let newClient = TestPRReviewClient(diffHandler: { _, _ in
            var diff = PRReviewDemo.diff()
            diff.files[0].hunks[0].lines[1].text = "current host code"
            return diff
        })
        let store = PRReviewStore()
        store.configure(client: oldClient, machineID: "old-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path

        let staleLoad = Task { await store.loadDiff(for: store.selectedPath) }
        await gate.waitUntilWaiting()
        store.configure(client: newClient, machineID: "new-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path
        await store.loadDiff(for: store.selectedPath)
        await gate.release()
        await staleLoad.value

        #expect(store.diff?.files[0].hunks[0].lines[1].text == "current host code")
    }

    @Test("A late file response cannot replace the newly selected file")
    func diffPathGuardDropsLateResponse() async {
        let firstPath = PRReviewDemo.snapshot().files[0].path
        let secondPath = PRReviewDemo.snapshot().files[1].path
        let gate = DiffResponseGate()
        let client = TestPRReviewClient(diffHandler: { _, path in
            if path == firstPath { await gate.wait() }
            var diff = PRReviewDemo.diff()
            diff.files[0].path = path ?? ""
            diff.files[0].hunks[0].lines[1].text = path == firstPath ? "old selection" : "new selection"
            return diff
        })
        let store = PRReviewStore()
        store.configure(client: client, machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = firstPath

        let firstLoad = Task { await store.loadDiff(for: firstPath) }
        await gate.waitUntilWaiting()
        store.selectedPath = secondPath
        await store.loadDiff(for: secondPath)
        await gate.release()
        await firstLoad.value

        #expect(store.diff?.files.first?.path == secondPath)
        #expect(store.diff?.files.first?.hunks[0].lines[1].text == "new selection")
    }

    @Test("A mismatched diff revision completes with an explicit retryable error")
    func mismatchedDiffRevisionReportsError() async {
        let client = TestPRReviewClient(diffHandler: { _, _ in
            var diff = PRReviewDemo.diff()
            diff.baseSHA = "different-base"
            return diff
        })
        let store = PRReviewStore()
        store.configure(client: client, machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path

        await store.loadDiff(for: store.selectedPath)

        #expect(store.diff == nil)
        #expect(store.currentDiffLoadError?.contains("different review revision") == true)
        #expect(store.completedDiffIdentity == store.currentDiffRequestIdentity)
        #expect(store.loadingDiffIdentity == nil)
    }

    @Test("A successful response missing the selected file completes instead of spinning")
    func missingSelectedDiffCompletesRequest() async {
        let client = TestPRReviewClient(diffHandler: { _, _ in
            var diff = PRReviewDemo.diff()
            diff.files = []
            return diff
        })
        let store = PRReviewStore()
        store.configure(client: client, machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path

        await store.loadDiff(for: store.selectedPath)

        #expect(store.diff?.files.isEmpty == true)
        #expect(store.completedDiffIdentity == store.currentDiffRequestIdentity)
        #expect(store.loadingDiffIdentity == nil)
        #expect(store.currentDiffLoadError == nil)
    }

    @Test("File and base/head changes produce new diff identities while ordinary polling does not")
    func diffIdentityTracksExactSource() {
        let store = PRReviewStore()
        store.configure(client: TestPRReviewClient(), machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        var snapshot = PRReviewDemo.snapshot()
        store.receive(snapshot)
        store.selectedPath = snapshot.files[0].path
        let original = store.currentDiffRequestIdentity

        snapshot.review.revision += 1
        store.receive(snapshot)
        #expect(store.currentDiffRequestIdentity == original)

        store.selectedPath = snapshot.files[1].path
        #expect(store.currentDiffRequestIdentity != original)
        store.selectedPath = snapshot.files[0].path
        snapshot.review.revision += 1
        snapshot.review.baseSHA = "new-base"
        store.receive(snapshot)
        let changedBase = store.currentDiffRequestIdentity
        #expect(changedBase != original)
        snapshot.review.revision += 1
        snapshot.review.headSHA = "new-head"
        store.receive(snapshot)
        #expect(store.currentDiffRequestIdentity != changedBase)
    }

    @Test("Polling does not clear the selected diff error")
    func pollingPreservesDiffError() async {
        let client = TestPRReviewClient(diffHandler: { _, _ in throw APIError.invalidResponse })
        let store = PRReviewStore()
        store.configure(client: client, machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        var snapshot = PRReviewDemo.snapshot()
        store.receive(snapshot)
        store.selectedPath = snapshot.files[0].path

        await store.loadDiff(for: store.selectedPath)
        let error = store.currentDiffLoadError
        snapshot.review.revision += 1
        store.receive(snapshot)

        #expect(error != nil)
        #expect(store.currentDiffLoadError == error)
    }

    @Test("A cancelled successful response cannot install a diff")
    func cancelledDiffLoadDoesNotMutateState() async {
        let gate = DiffResponseGate()
        let client = TestPRReviewClient(diffHandler: { _, _ in
            await gate.wait()
            return PRReviewDemo.diff()
        })
        let store = PRReviewStore()
        store.configure(client: client, machineID: "review-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path

        let load = Task { await store.loadDiff(for: store.selectedPath) }
        await gate.waitUntilWaiting()
        load.cancel()
        await gate.release()
        await load.value

        #expect(store.diff == nil)
    }
}

private actor DiffResponseGate {
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

/// Shared by the PR Review store suites; internal so a deleted-file revision
/// regression can drive a failing diff load with the same stub.
final class TestPRReviewClient: PRReviewClient, @unchecked Sendable {
    private let delay: Duration?
    private let capabilitiesError: APIError?
    private let reviewError: APIError?
    private let createdReviewID: String?
    private let diffHandler: (@Sendable (String, String?) async throws -> PRReviewDiff)?

    init(
        delay: Duration? = nil,
        capabilitiesError: APIError? = nil,
        reviewError: APIError? = nil,
        createdReviewID: String? = nil,
        diffHandler: (@Sendable (String, String?) async throws -> PRReviewDiff)? = nil
    ) {
        self.delay = delay
        self.capabilitiesError = capabilitiesError
        self.reviewError = reviewError
        self.createdReviewID = createdReviewID
        self.diffHandler = diffHandler
    }

    func prReviewCapabilities() async throws -> PRReviewCapabilities {
        if let capabilitiesError {
            throw capabilitiesError
        }
        try await pauseIfNeeded()
        return try decode("{\"ok\":true,\"capabilities\":[\"pr-review-v1\"],\"available\":true,\"skills\":[]}")
    }

    func prReviewSkills() async throws -> [PRReviewSkill] { [] }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { PRReviewDemo.snapshot().skills[0].skill }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { [] }
    func prReviews(scope: String) async throws -> [PRReviewSummary] { [PRReviewDemo.snapshot().review] }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot {
        var snapshot = PRReviewDemo.snapshot()
        if let createdReviewID { snapshot.review.id = createdReviewID }
        return snapshot
    }
    func prReview(id: String) async throws -> PRReviewSnapshot {
        if let reviewError { throw reviewError }
        return PRReviewDemo.snapshot()
    }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot { PRReviewDemo.snapshot() }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot { PRReviewDemo.snapshot() }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff {
        if let diffHandler { return try await diffHandler(id, path) }
        return PRReviewDemo.diff()
    }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText { throw APIError.invalidResponse }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { throw APIError.invalidResponse }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func finishPRReviewRun(reviewID: String, runID: String, state: PRReviewRunState, note: String?, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { "" }
    func markPRReviewSkill(reviewID: String, skillID: String, state: String, note: String?, requestID: String) async throws -> PRReviewSkillState { PRReviewDemo.snapshot().skills[0] }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary { PRReviewDemo.snapshot().review }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { [] }
    func setPRReviewViewed(id: String, paths: [String], viewed: Bool, requestID: String) async throws -> [PRReviewFile] {
        try await pauseIfNeeded()
        return PRReviewDemo.snapshot().files
    }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { [] }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { [] }
    func addPRReviewDocument(id: String, payload: PRReviewDocumentPayload, requestID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws { throw APIError.invalidResponse }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { [] }

    private func pauseIfNeeded() async throws {
        if let delay {
            try await Task.sleep(for: delay)
        }
    }

    private func decode<T: Decodable>(_ string: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(string.utf8))
    }
}
