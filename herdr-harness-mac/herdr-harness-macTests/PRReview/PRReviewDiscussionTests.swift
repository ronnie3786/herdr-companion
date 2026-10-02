import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review host discussions")
struct PRReviewDiscussionTests {
    @Test("Wire responses retain both sides, exact text, comparison identity, and revision history")
    func responseContractRoundTrips() throws {
        let json = #"""
        {"threads":[{"id":"thread-1","review_id":"review-a","state":"resolved","outdated":true,
        "created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-02T10:00:00Z","version":3,
        "anchor":{"path":"Sources/Seed.swift","base_sha":"base-original","head_sha":"head-original",
        "spans":[{"side":"before","start":4,"end":5},{"side":"after","start":4,"end":6}],
        "code_excerpt":"  let seed = 1\n",
        "comparison":{"id":"range-1","mode":"range","before_sha":"commit-a","after_sha":"commit-b","commit_shas":["commit-b"]},
        "comparison_selection":{"mode":"range","start_commit":"commit-a","end_commit":"commit-b"}},
        "messages":[{"id":"message-1","author":"agent","body":"  Swift reviewer: preserve 🧪\n\tspacing  \n","created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T10:00:00Z"},
        {"id":"message-2","author":"human","body":"Verified.","created_at":"2026-10-02T09:00:00Z","updated_at":"2026-10-02T09:00:00Z"}],
        "history":[{"id":"event-1","action":"resolved","author":"human","created_at":"2026-10-02T10:00:00Z","base_sha":"base-current","head_sha":"head-current"}]}]}
        """#
        let response = try JSONDecoder().decode(PRReviewDiscussionsResponse.self, from: Data(json.utf8))
        let thread = try #require(response.threads.first)
        let anchor = try #require(thread.anchor)
        #expect(thread.isResolved)
        #expect(thread.outdated)
        #expect(thread.version == 3)
        #expect(thread.reviewID == "review-a")
        #expect(anchor.spans == [.init(side: .before, start: 4, end: 5), .init(side: .after, start: 4, end: 6)])
        #expect(anchor.headSHA == "head-original")
        #expect(anchor.codeExcerpt == "  let seed = 1\n")
        #expect(anchor.comparison?.beforeSHA == "commit-a")
        #expect(anchor.comparison?.afterSHA == "commit-b")
        #expect(anchor.comparison?.commitSHAs == ["commit-b"])
        #expect(anchor.comparisonSelection == .init(mode: .range, startCommit: "commit-a", endCommit: "commit-b"))
        #expect(thread.messages.map(\.authorLabel) == ["Agent", "Human"])
        #expect(thread.messages[0].body == "  Swift reviewer: preserve 🧪\n\tspacing  \n")
        #expect(thread.history.first?.headSHA == "head-current")
        let encoded = try JSONEncoder().encode(thread)
        #expect(try JSONDecoder().decode(PRReviewDiscussion.self, from: encoded) == thread)
    }

    @Test("Create, reply, and state mutations encode the companion's snake case contract")
    func mutationRequestContract() throws {
        let body = "  Please check.\n"
        let anchor = PRReviewDiscussionCreate.Anchor(
            path: "Sources/Seed.swift", baseSHA: "base-original", headSHA: "head-original",
            spans: [.init(side: .before, start: 4, end: 5), .init(side: .after, start: 4, end: 6)],
            comparison: .init(mode: .range, startCommit: "commit-a", endCommit: "commit-b")
        )
        let create = try object(PRReviewDiscussionCreate(body: body, requestID: "create-request", anchor: anchor))
        #expect(create["body"] as? String == body)
        #expect(create["author"] as? String == "human")
        #expect(create["request_id"] as? String == "create-request")
        let encodedAnchor = try #require(create["anchor"] as? [String: Any])
        #expect(encodedAnchor["base_sha"] as? String == "base-original")
        #expect(encodedAnchor["head_sha"] as? String == "head-original")
        let spans = try #require(encodedAnchor["spans"] as? [[String: Any]])
        #expect(spans.compactMap { $0["side"] as? String } == ["before", "after"])
        let comparison = try #require(encodedAnchor["comparison"] as? [String: Any])
        #expect(comparison["mode"] as? String == "range")
        #expect(comparison["start_commit"] as? String == "commit-a")
        #expect(comparison["end_commit"] as? String == "commit-b")

        let reply = try object(PRReviewDiscussionReply(body: body, requestID: "reply-request"))
        #expect(reply["body"] as? String == body)
        #expect(reply["request_id"] as? String == "reply-request")
        #expect(reply["author"] as? String == "human")
        let state = try object(PRReviewDiscussionStateChange(state: "resolved", expectedVersion: 7, requestID: "state-request"))
        #expect(state["state"] as? String == "resolved")
        #expect(state["expected_version"] as? Int == 7)
        #expect(state["request_id"] as? String == "state-request")
    }

    @Test("A delayed refresh cannot cross host, review, or connection generation", arguments: ["machine", "review", "generation"])
    func refreshRetiresEachScopeComponent(_ changed: String) async {
        let gate = DiscussionResponseGate()
        let oldClient = DiscussionTestClient(threads: [discussionFixture(id: "old-thread")])
        await oldClient.holdNextList(on: gate)
        let session = configuredSession(client: oldClient)
        let request = Task { await session.refresh() }
        await gate.waitUntilWaiting()
        #expect(session.isLoading)

        var next = scope
        switch changed {
        case "machine": next.machineID = "host-b"
        case "review": next.reviewID = "review-b"
        default: next.generation += 1
        }
        let expected = discussionFixture(id: "new-thread", reviewID: next.reviewID)
        let newClient = DiscussionTestClient(threads: [expected])
        session.configure(scope: next, client: newClient, available: true)
        #expect(session.threads.isEmpty)
        #expect(!session.isLoading)
        await session.refresh()
        await gate.release()
        await request.value
        #expect(session.threads == [expected])
        #expect(session.error == nil)
        #expect(!session.isLoading)
        #expect(await newClient.listReviewIDs == [next.reviewID])
    }

    @Test("A delayed refresh failure cannot appear on another review")
    func staleRefreshErrorIsIgnored() async {
        let gate = DiscussionResponseGate()
        let client = DiscussionTestClient()
        await client.holdNextList(on: gate, failure: .unavailable)
        let session = configuredSession(client: client)
        let request = Task { await session.refresh() }
        await gate.waitUntilWaiting()
        session.configure(scope: .init(machineID: "host-b", reviewID: "review-a", generation: 1),
                          client: DiscussionTestClient(), available: true)
        await gate.release()
        await request.value
        #expect(session.error == nil)
        #expect(!session.isLoading)
    }

    @Test("A refresh started before a reply cannot erase the successfully saved reply")
    func mutationRetiresOlderRefresh() async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        let gate = DiscussionResponseGate()
        await client.holdNextList(on: gate)
        let request = Task { await session.refresh() }
        await gate.waitUntilWaiting()
        session.beginReply(to: original)
        session.draftBody = "Confirmed with the updated call site."
        await session.save()
        let saved = try #require(session.threads.first)
        #expect(saved.messages.count == 2)
        await gate.release()
        await request.value
        #expect(session.threads == [saved])
        #expect(!session.isLoading)
    }

    @Test("An older mutation receipt cannot replace a newer version already received by polling", arguments: ["reply", "state"])
    func olderMutationReceiptPreservesNewerPoll(_ operation: String) async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        let gate = DiscussionResponseGate()
        await client.holdNextMutation(on: gate)
        if operation == "reply" {
            session.beginReply(to: original)
            session.draftBody = "The first mutation."
        }
        let request = Task {
            if operation == "reply" { await session.save() }
            else { await session.toggleState(original) }
        }
        await gate.waitUntilWaiting()
        var newer = discussionFixture(version: 3)
        newer.state = "resolved"
        newer.messages.append(.init(id: "newer-reply", author: "agent", body: "A later response already arrived.",
                                    createdAt: "2026-10-02T11:00:00Z", updatedAt: "2026-10-02T11:00:00Z"))
        await client.replaceThreads([newer])
        await session.refresh()
        #expect(session.threads == [newer])
        await gate.release()
        await request.value
        #expect(session.threads == [newer])
        #expect(session.draft == nil)
        #expect(!session.isSaving)
        if operation == "reply" { #expect(session.visibleThreads == [newer]) }
    }

    @Test("A delayed receipt preserves revision age from a newer poll", arguments: [1, 2])
    func mutationPreservesPolledRevisionAge(_ polledVersion: Int) async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        let gate = DiscussionResponseGate()
        await client.holdNextMutation(on: gate)
        session.beginReply(to: original)
        session.draftBody = "A reply before the PR changed."
        let request = Task { await session.save() }
        await gate.waitUntilWaiting()
        var polled = discussionFixture(version: polledVersion)
        polled.outdated = true
        await client.replaceThreads([polled])
        await session.refresh()
        await gate.release()
        await request.value
        #expect(session.threads.first?.version == 2)
        #expect(session.threads.first?.outdated == true)
    }

    @Test("Discussion drafts survive a pinned window losing and restoring its host")
    func draftSurvivesHostUnavailability() async {
        let target = PRReviewWindowTarget(machineID: "host-a", reviewID: PRReviewDemo.reviewID)
        let window = PRReviewWindowSession(target: target)
        defer { window.stop() }
        await window.activate(identity: "demo", hostState: .demo, client: nil, seed: nil)
        let session = window.store.discussions
        session.beginComment(store: window.store)
        session.draftBody = "Preserve this draft while credentials are updated."
        let originalScope = session.draft?.scope
        #expect(session.canSave)
        await window.activate(identity: "missing", hostState: .missingHost, client: nil, seed: nil)
        #expect(!session.isAvailable)
        #expect(session.hasDraft)
        await window.activate(identity: "restored", hostState: .demo, client: nil, seed: nil)
        #expect(window.store.discussions.draftBody == "Preserve this draft while credentials are updated.")
        #expect(session.draft?.scope == originalScope)
        #expect(!session.canSave)
        #expect(session.isPresented)
    }

    @Test("Reply text reaches the original thread unchanged and a successful save clears the draft")
    func replyPreservesExactBody() async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        session.beginReply(to: original)
        session.draftBody = "  Human response 🧪\n\tkeep spacing  \n"
        await session.save()
        let reply = try #require(await client.replies.first)
        #expect(reply.reviewID == scope.reviewID)
        #expect(reply.threadID == original.id)
        #expect(reply.request.author == "human")
        #expect(reply.request.body == "  Human response 🧪\n\tkeep spacing  \n")
        #expect(session.threads.first?.messages.last?.body == reply.request.body)
        #expect(session.draft == nil)
        #expect(session.draftBody.isEmpty)
        #expect(session.selectedThreadID == original.id)
        #expect(!session.isSaving)
        #expect(session.error == nil)
    }

    @Test("Failed saves preserve the draft and retries reuse the request ID for unchanged text")
    func failedSaveRetainsDraftAndIdempotencyKey() async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        session.beginReply(to: original)
        session.draftBody = "  Retry this reply exactly.\n"
        let requestID = try #require(session.draft?.requestID)
        await client.failNextReply()
        await session.save()
        #expect(session.draft?.requestID == requestID)
        #expect(session.draftBody == "  Retry this reply exactly.\n")
        #expect(session.threads == [original])
        #expect(session.error != nil)
        #expect(session.canSave)
        #expect(!session.isSaving)

        await session.save()
        let requests = await client.replies
        #expect(requests.map(\.request.requestID) == [requestID, requestID])
        #expect(requests.map(\.request.body) == ["  Retry this reply exactly.\n", "  Retry this reply exactly.\n"])
        #expect(session.draft == nil)
        #expect(session.threads.first?.messages.count == 2)
    }

    @Test("Editing a failed draft allocates a new request ID before retry")
    func changedBodyUsesNewRequestID() async throws {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        session.beginReply(to: original)
        session.draftBody = "Original request."
        await client.failNextReply()
        await session.save()
        session.draftBody = "Revised request."
        await session.save()
        let requests = await client.replies
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let last = try #require(requests.last)
        #expect(first.request.requestID != last.request.requestID)
        #expect(last.request.body == "Revised request.")
    }

    @Test("Resolve and reopen send explicit state with the currently displayed version")
    func explicitStateChangesUseOptimisticVersion() async throws {
        let original = discussionFixture(version: 7)
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        await session.toggleState(original)
        let resolved = try #require(session.threads.first)
        #expect(resolved.isResolved)
        #expect(resolved.version == 8)
        await session.toggleState(resolved)
        let requests = await client.stateChanges
        #expect(requests.map(\.request.state) == ["resolved", "open"])
        #expect(requests.map(\.request.expectedVersion) == [7, 8])
        #expect(requests.allSatisfy { $0.reviewID == scope.reviewID && $0.threadID == original.id })
        #expect(session.threads.first?.state == "open")
        #expect(session.openCount == 1)
    }

    @Test("A stale state mutation refreshes the current thread without silently retrying the mutation")
    func staleStateRefreshesBeforeExplicitRetry() async throws {
        let original = discussionFixture(version: 1)
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        let concurrent = discussionFixture(version: 2)
        await client.replaceThreads([concurrent])
        await session.toggleState(original)
        #expect(await client.stateChanges.count == 1)
        #expect(session.threads == [concurrent])
        #expect(session.error != nil)
        #expect(session.threads.first?.state == "open")
        #expect(!session.isSaving)
        let refreshed = try #require(session.threads.first)
        await session.toggleState(refreshed)
        #expect(await client.stateChanges.map(\.request.expectedVersion) == [1, 2])
        #expect(session.threads.first?.state == "resolved")
        #expect(session.error == nil)
    }

    @Test("A PR-level comment saves without a code anchor")
    func createsPRLevelComment() async throws {
        let client = DiscussionTestClient()
        let session = configuredSession(client: client)
        let store = PRReviewStore()
        store.configure(client: nil, machineID: scope.machineID, demo: false)
        store.select(scope.reviewID)
        session.beginComment(store: store)
        #expect(session.draft?.anchor == nil)
        #expect(session.hasDraft)
        session.draftBody = "Question about the overall approach."
        await session.save()
        let creation = try #require(await client.creations.first)
        #expect(creation.reviewID == scope.reviewID)
        #expect(creation.request.anchor == nil)
        #expect(creation.request.author == "human")
        #expect(creation.request.body == "Question about the overall approach.")
        let encoded = try object(creation.request)
        #expect(encoded["anchor"] == nil)
        #expect(session.threads.first?.anchor == nil)
        #expect(!session.hasDraft)
    }

    @Test("A draft never follows a user onto another host or connection")
    func draftRemainsBoundToOriginalScope() async {
        let original = discussionFixture()
        let oldClient = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: oldClient)
        await session.refresh()
        session.beginReply(to: original)
        session.draftBody = "Belongs to host A."
        let newClient = DiscussionTestClient(threads: [original])
        session.configure(scope: .init(machineID: "host-b", reviewID: scope.reviewID, generation: 2),
                          client: newClient, available: true)
        #expect(session.hasDraft)
        #expect(session.draftBody == "Belongs to host A.")
        #expect(!session.canSave)
        await session.save()
        #expect(await oldClient.replies.isEmpty)
        #expect(await newClient.replies.isEmpty)
        session.discardDraft()
        #expect(!session.hasDraft)
    }

    @Test("Whitespace and unavailable capabilities prevent mutations")
    func unavailableOrBlankDraftCannotSave() async {
        let original = discussionFixture()
        let client = DiscussionTestClient(threads: [original])
        let session = configuredSession(client: client)
        await session.refresh()
        session.beginReply(to: original)
        session.draftBody = " \n\t "
        #expect(!session.canSave)
        await session.save()
        session.draftBody = "Valid body."
        session.configure(scope: scope, client: client, available: false)
        #expect(!session.canSave)
        await session.save()
        #expect(await client.replies.isEmpty)
        #expect(session.draftBody == "Valid body.")
    }

    @Test("A cancelled refresh settles the loading indicator without publishing a response")
    func cancelledRefreshSettlesLoading() async {
        let gate = DiscussionResponseGate()
        let client = DiscussionTestClient(threads: [discussionFixture()])
        await client.holdNextList(on: gate)
        let session = configuredSession(client: client)
        let request = Task { await session.refresh() }
        await gate.waitUntilWaiting()
        request.cancel()
        await gate.release()
        await request.value
        #expect(session.threads.isEmpty)
        #expect(session.error == nil)
        #expect(!session.isLoading)
    }

    private var scope: PRReviewDiscussionSession.Scope {
        .init(machineID: "host-a", reviewID: "review-a", generation: 1)
    }

    private func configuredSession(client: DiscussionTestClient) -> PRReviewDiscussionSession {
        let session = PRReviewDiscussionSession()
        session.configure(scope: scope, client: client, available: true)
        return session
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}

private func discussionFixture(id: String = "thread-1", reviewID: String = "review-a", version: Int = 1) -> PRReviewDiscussion {
    PRReviewDiscussion(
        id: id, reviewID: reviewID, state: "open", anchor: nil, outdated: false,
        createdAt: "2026-10-01T10:00:00Z", updatedAt: "2026-10-01T10:00:00Z", version: version,
        messages: [.init(id: "message-1", author: "agent", body: "Synthetic finding.",
                         createdAt: "2026-10-01T10:00:00Z", updatedAt: "2026-10-01T10:00:00Z")],
        history: []
    )
}

private enum DiscussionTestError: Error, LocalizedError, Sendable {
    case unavailable, staleVersion
    var errorDescription: String? {
        switch self {
        case .unavailable: "Synthetic companion unavailable."
        case .staleVersion: "Synthetic thread version changed."
        }
    }
}

private actor DiscussionTestClient: PRReviewDiscussionClient {
    struct Creation: Sendable {
        var reviewID: String
        var request: PRReviewDiscussionCreate
    }
    struct Reply: Sendable {
        var reviewID: String
        var threadID: String
        var request: PRReviewDiscussionReply
    }
    struct StateChange: Sendable {
        var reviewID: String
        var threadID: String
        var request: PRReviewDiscussionStateChange
    }
    private var threads: [PRReviewDiscussion]
    private var listGate: DiscussionResponseGate?
    private var listFailure: DiscussionTestError?
    private var replyShouldFail = false
    private var mutationGate: DiscussionResponseGate?
    private(set) var listReviewIDs: [String] = []
    private(set) var creations: [Creation] = []
    private(set) var replies: [Reply] = []
    private(set) var stateChanges: [StateChange] = []

    init(threads: [PRReviewDiscussion] = []) { self.threads = threads }

    func replaceThreads(_ value: [PRReviewDiscussion]) { threads = value }
    func failNextReply() { replyShouldFail = true }
    func holdNextMutation(on gate: DiscussionResponseGate) { mutationGate = gate }
    func holdNextList(on gate: DiscussionResponseGate, failure: DiscussionTestError? = nil) {
        listGate = gate
        listFailure = failure
    }

    func prReviewDiscussions(reviewID: String) async throws -> [PRReviewDiscussion] {
        listReviewIDs.append(reviewID)
        let snapshot = threads
        let gate = listGate
        let failure = listFailure
        listGate = nil
        listFailure = nil
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return snapshot
    }

    func createPRReviewDiscussion(reviewID: String, request: PRReviewDiscussionCreate) async throws -> PRReviewDiscussion {
        creations.append(.init(reviewID: reviewID, request: request))
        var thread = discussionFixture(id: "created-thread", reviewID: reviewID)
        thread.messages[0].author = request.author
        thread.messages[0].body = request.body
        if let anchor = request.anchor {
            thread.anchor = .init(path: anchor.path, baseSHA: anchor.baseSHA, headSHA: anchor.headSHA,
                                  spans: anchor.spans, comparisonSelection: anchor.comparison)
        }
        threads.append(thread)
        return thread
    }

    func replyToPRReviewDiscussion(reviewID: String, threadID: String, request: PRReviewDiscussionReply) async throws -> PRReviewDiscussion {
        replies.append(.init(reviewID: reviewID, threadID: threadID, request: request))
        if replyShouldFail {
            replyShouldFail = false
            throw DiscussionTestError.unavailable
        }
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { throw DiscussionTestError.unavailable }
        threads[index].messages.append(.init(id: "reply-\(replies.count)", author: request.author, body: request.body,
                                             createdAt: "2026-10-02T10:00:00Z", updatedAt: "2026-10-02T10:00:00Z"))
        threads[index].version += 1
        let result = threads[index]
        let gate = mutationGate
        mutationGate = nil
        if let gate { await gate.wait() }
        return result
    }

    func setPRReviewDiscussionState(reviewID: String, threadID: String, request: PRReviewDiscussionStateChange) async throws -> PRReviewDiscussion {
        stateChanges.append(.init(reviewID: reviewID, threadID: threadID, request: request))
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { throw DiscussionTestError.unavailable }
        guard threads[index].version == request.expectedVersion else { throw DiscussionTestError.staleVersion }
        threads[index].state = request.state
        threads[index].version += 1
        let result = threads[index]
        let gate = mutationGate
        mutationGate = nil
        if let gate { await gate.wait() }
        return result
    }
}

private actor DiscussionResponseGate {
    private var isWaiting = false
    private var response: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isWaiting = true
        let pending = arrivals
        arrivals.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { response = $0 }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        response?.resume()
        response = nil
    }
}
