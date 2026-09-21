import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review window routing", .serialized)
struct PRReviewWindowRoutingTests {
    @Test("Distinct reviews keep distinct targets even with duplicate labels and numbers")
    func duplicatePresentationStillRoutesToDistinctReviews() {
        var first = PRReviewDemo.snapshot().review
        first.number = 12
        first.title = "Shared synthetic title"
        var second = first
        second.id = "prr_second_review"

        let firstTarget = PRReviewWindowTarget(machineID: "review-host", reviewID: first.id)
        let secondTarget = PRReviewWindowTarget(machineID: "review-host", reviewID: second.id)

        #expect(firstTarget != secondTarget)
        #expect(firstTarget.windowAccessibilityIdentifier != secondTarget.windowAccessibilityIdentifier)
    }

    @Test("Identical review ids on different hosts route to different windows")
    func identicalReviewIDsOnDifferentHostsRouteApart() {
        let targets = ["host-one", "host-two"].map {
            PRReviewWindowTarget(machineID: $0, reviewID: "prr_collision")
        }

        #expect(targets[0] != targets[1])
        #expect(Set(targets).count == 2)
        #expect(targets[0].windowAccessibilityIdentifier != targets[1].windowAccessibilityIdentifier)
    }

    @Test("A removed pinned host never falls back to the default review host")
    func removedHostNeverFallsBack() throws {
        let defaults = try testDefaults()
        let credentials = TestCredentialStore()
        credentials.values["api-token.default-host"] = "synthetic-default-token"
        credentials.values["api-token.review-host"] = "synthetic-review-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        model.machines = [
            HerdrMachine(
                id: "default-host",
                name: "Default",
                urlString: "https://default-host.example.invalid",
                role: "development"
            ),
            HerdrMachine(
                id: "review-host",
                name: "Review",
                urlString: "https://review-host.example.invalid"
            ),
        ]

        #expect(model.prReviewConfiguration()?.baseURL.absoluteString == "https://default-host.example.invalid")
        #expect(model.prReviewConfiguration(pinnedMachineID: "review-host")?.baseURL.absoluteString == "https://review-host.example.invalid")

        model.machines = [model.machines[0]]
        #expect(model.prReviewConfiguration(pinnedMachineID: "review-host") == nil)
        #expect(model.prReviewConfiguration(machineID: "review-host") == nil)
        #expect(model.prReviewConfiguration() != nil)
        #expect(model.prReviewWindowHostResolution(for: "review-host").state == .missingHost)
        #expect(model.prReviewWindowHostResolution(for: "review-host").client == nil)

        model.machines = [
            model.machines[0],
            HerdrMachine(
                id: "review-host",
                name: "Review",
                urlString: "https://review-host.example.invalid"
            ),
        ]
        #expect(model.prReviewConfiguration(pinnedMachineID: "review-host") != nil)
        #expect(model.prReviewWindowHostResolution(for: "review-host").state == .available)
        #expect(model.prReviewWindowHostResolution(for: "review-host").client != nil)
    }

    @Test("A token-only credential update re-activates a pinned window without exposing the token")
    func tokenOnlyUpdateChangesPinnedIdentity() async throws {
        let defaults = try testDefaults()
        let credentials = TestCredentialStore()
        credentials.values["api-token.review-host"] = "synthetic-before-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        model.machines = [
            HerdrMachine(id: "review-host", name: "Review", urlString: "https://review-host.example.invalid"),
        ]
        let target = PRReviewWindowTarget(machineID: "review-host", reviewID: PRReviewDemo.reviewID)
        func probe() -> PRReviewWindowHostProbe {
            model.prReviewWindowHostProbe(for: target.machineID)
        }

        let before = probe()
        #expect(model.prReviewWindowHostResolution(for: target.machineID).state == .available)
        let first = SyntheticPRReviewWindowClient()
        let session = PRReviewWindowSession(target: target)
        await session.activate(identity: before.identifier, hostState: .available, client: first, seed: nil)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(await first.reviewIDs == [PRReviewDemo.reviewID])

        #expect(model.updateMachine(
            id: "review-host",
            name: "Review",
            urlString: "https://review-host.example.invalid",
            token: "synthetic-after-token"
        ))
        let after = probe()

        // A token-only edit keeps the same URL and machine, so the activation
        // identity must change through the configuration revision instead.
        #expect(before.machineExists == after.machineExists)
        #expect(before.configurationURL == after.configurationURL)
        #expect(before != after)
        #expect(before.identifier != after.identifier)
        #expect(!before.identifier.contains("synthetic-before-token"))
        #expect(!after.identifier.contains("synthetic-after-token"))
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: after.isDemoTarget,
            targetMachineExists: after.machineExists,
            hasConfiguration: after.configurationURL != nil
        ) == .available)

        // Re-activating through the changed probe swaps in a client for the new
        // credential while keeping the loaded review and its presentation.
        session.store.selectedPath = "Sources/Models/Seed.swift"
        let second = SyntheticPRReviewWindowClient()
        await session.activate(identity: after.identifier, hostState: .available, client: second, seed: nil)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(session.store.selectedPath == "Sources/Models/Seed.swift")
        #expect(await second.reviewIDs == [PRReviewDemo.reviewID])

        await session.store.loadDiff(for: "Sources/Models/Seed.swift")
        #expect(await second.diffPaths == ["Sources/Models/Seed.swift"])
        #expect(await first.diffPaths.isEmpty)
    }

    @Test("Two active reviews stay open in independent sessions")
    func twoActiveReviewsStayIndependent() async {
        let first = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "review-host", reviewID: PRReviewDemo.reviewID)
        )
        let second = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "review-host", reviewID: PRReviewDemo.secondReviewID)
        )

        await first.activate(identity: "first", hostState: .available, client: SyntheticPRReviewWindowClient(), seed: nil)
        await second.activate(identity: "second", hostState: .available, client: SyntheticPRReviewWindowClient(), seed: nil)

        #expect(first.store !== second.store)
        #expect(first.store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(second.store.selectedReviewID == PRReviewDemo.secondReviewID)
        #expect(first.store.snapshot?.review.id != second.store.snapshot?.review.id)

        first.stop()
        #expect(second.isPolling)
        #expect(second.store.selectedReviewID == PRReviewDemo.secondReviewID)
    }

    @Test("Main-window host and selection changes never retarget a pop-out")
    func mainWindowChangesDoNotRetargetPopOut() async throws {
        let defaults = try testDefaults()
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        model.machines = [
            HerdrMachine(id: "review-host", name: "Review", urlString: "https://review-host.example.invalid"),
            HerdrMachine(id: "other-host", name: "Other", urlString: "https://other-host.example.invalid"),
        ]
        let shell = HerdrShellState(userDefaults: defaults)
        shell.prReviewMachineID = "other-host"

        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "review-host", reviewID: PRReviewDemo.reviewID)
        )
        await session.activate(
            identity: "review-host",
            hostState: .available,
            client: SyntheticPRReviewWindowClient(),
            seed: nil
        )

        shell.prReviewMachineID = "review-host"
        shell.prReview.select(PRReviewDemo.secondReviewID)
        shell.showActiveWork()

        #expect(session.target.machineID == "review-host")
        #expect(session.store.currentMachineID == "review-host")
        #expect(session.store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
    }

    @Test("Ask AI excerpts and findings come from the explicit machine only")
    func askAIQuestionPlanIsHostScoped() async throws {
        let defaults = try testDefaults()
        let credentials = TestCredentialStore()
        credentials.values["api-token.review-host"] = "synthetic-review-token"
        credentials.values["api-token.other-host"] = "synthetic-other-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let reviewHost = HerdrMachine(id: "review-host", name: "Review", urlString: "https://review-host.example.invalid")
        let otherHost = HerdrMachine(id: "other-host", name: "Other", urlString: "https://other-host.example.invalid")
        model.machines = [reviewHost, otherHost]

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewQuestionURLProtocol.self]
        model.clientFactory = { configuration in
            HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        }
        model.prepareRuntime(for: reviewHost, generation: 0)
        model.prepareRuntime(for: otherHost, generation: 0)

        var review = PRReviewDemo.snapshot().review
        review.checkoutPath = "/tmp/synthetic-checkout"
        let selection = PRReviewSelection(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [.init(side: .after, start: 2, end: 2)],
            text: "struct SeedCatalog {}"
        )

        PRReviewQuestionURLProtocol.reset()
        let plan = await model.prReviewQuestionPlan(machineID: reviewHost.id, review: review, selection: selection)

        #expect(plan?.machineID == reviewHost.id)
        #expect(plan?.checkoutPath == "/tmp/synthetic-checkout")
        #expect(plan?.context.items.contains { $0.id == "excerpt" } == true)
        #expect(plan?.context.items.contains { $0.id == "findings" } == true)
        let requests = PRReviewQuestionURLProtocol.recordedRequests()
        #expect(requests.contains { $0.url?.path.hasSuffix("/file") == true })
        #expect(requests.contains { $0.url?.path.hasSuffix("/findings") == true })
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.url?.host == "review-host.example.invalid" })
    }

    @Test("A missing checkout keeps Ask AI unavailable instead of routing elsewhere")
    func missingCheckoutDoesNotRoute() async throws {
        let defaults = try testDefaults()
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        var review = PRReviewDemo.snapshot().review
        review.checkoutPath = nil
        let selection = PRReviewSelection(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [],
            text: ""
        )

        let plan = await model.prReviewQuestionPlan(
            machineID: "review-host",
            review: review,
            selection: selection
        )

        #expect(plan == nil)
        #expect(model.toastMessage != nil)
    }

    /// Each test gets an isolated, uniquely named domain so no state leaks
    /// between routing cases; the suite is discarded when the process exits.
    private func testDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "PRReviewWindowRoutingTests.\(UUID().uuidString)"))
    }
}

private final class PRReviewQuestionURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static func reset() {
        state.withLock { $0.requests.removeAll() }
    }

    static func recordedRequests() -> [URLRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.withLock { $0.requests.append(request) }
        let path = request.url?.path ?? ""
        let body: Data
        if path.hasSuffix("/file") {
            body = Data("""
            {"ok":true,"path":"Sources/Catalog/SeedCatalog.swift","side":"after","start_line":1,"end_line":80,"total_lines":80,"text":"synthetic excerpt"}
            """.utf8)
        } else if path.hasSuffix("/findings") {
            body = Data("""
            {"ok":true,"path":"Sources/Catalog/SeedCatalog.swift","text":"synthetic findings","document_ids":[]}
            """.utf8)
        } else {
            body = Data("{\"ok\":true}".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
