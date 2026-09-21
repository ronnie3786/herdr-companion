import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review store")
struct PRReviewStoreTests {
    @Test("Configure resets state and seeds the synthetic demo")
    func configureResetsAndSeedsDemo() async {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        await store.refresh()

        #expect(store.reviews.count == 1)
        #expect(store.archivedReviews.count == 1)
        #expect(store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(store.snapshot?.review.id == PRReviewDemo.reviewID)
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
}

private final class TestPRReviewClient: PRReviewClient, @unchecked Sendable {
    private let delay: Duration?
    private let capabilitiesError: APIError?
    private let reviewError: APIError?
    private let createdReviewID: String?

    init(delay: Duration? = nil, capabilitiesError: APIError? = nil, reviewError: APIError? = nil, createdReviewID: String? = nil) {
        self.delay = delay
        self.capabilitiesError = capabilitiesError
        self.reviewError = reviewError
        self.createdReviewID = createdReviewID
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
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { PRReviewDemo.diff() }
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
