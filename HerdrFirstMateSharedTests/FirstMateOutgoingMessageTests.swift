import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

/// Optimistic First Mate sends: the local row appears before the transport
/// returns, and only an authoritative receipt or row retires it. Every test
/// uses a deferred synthetic client with bounded waits, so ordering is
/// deterministic rather than timing-based.
@Suite("First Mate optimistic outgoing messages", .serialized)
@MainActor
struct FirstMateOutgoingMessageTests {
    @Test("A submission is published before its transport starts")
    func pendingPresentation() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        let snapshot = try #require(store.snapshot)

        let handle = try #require(store.beginOutgoingMessage("Plan the change", expectedContext: context))
        let rows = store.conversationMessages(for: snapshot)
        let row = try #require(rows.last)
        #expect(row.id == handle.outgoingID)
        #expect(row.role == "user")
        #expect(row.text == "Plan the change")
        #expect(row.status == "sending")
        #expect(FirstMateOutgoingMessage.isLocalID(row.id))
        #expect(store.newestServerMessageID(for: snapshot) != row.id)
        #expect(store.isSubmitting(featureID: alphaID))
        #expect(store.isAwaitingSendResolution(featureID: alphaID))
        #expect(store.outgoingMessages(for: alphaID).last?.state == .pending)

        // Still true while the request is suspended, and the row is ordered
        // before any working feedback the transcript appends after its rows.
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        #expect(store.outgoingMessages(for: alphaID).last?.state == .pending)
        #expect(store.conversationMessages(for: snapshot).last?.id == handle.outgoingID)

        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_accepted", "Plan the change"))))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: "fmm_accepted"))
        #expect(!store.isSubmitting(featureID: alphaID))
        #expect(store.isAwaitingSendResolution(featureID: alphaID))
    }

    @Test("A receipt row retires the local row only once the poll includes it")
    func receiptBeforePoll() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Ship it", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_saved", "Ship it"))))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: "fmm_saved"))

        // The accepted message is presented locally until the authoritative
        // conversation carries it.
        let beforePoll = try #require(store.snapshot)
        #expect(store.conversationMessages(for: beforePoll).map(\.id) == [handle.outgoingID])
        #expect(store.isAwaitingSendResolution(featureID: alphaID))

        store.receive(makeSnapshot(id: alphaID, messages: [message("fmm_saved", "Ship it", status: "processing")]))
        let rows = store.conversationMessages(for: try #require(store.snapshot))
        #expect(rows.map(\.id) == ["fmm_saved"])
        #expect(rows.first?.status == "processing")
        #expect(store.outgoingMessages(for: alphaID).first?.acceptedStatus == "processing")
        #expect(!store.isAwaitingSendResolution(featureID: alphaID))
    }

    @Test("A partial snapshot never removes an acknowledged row or resurrects its local row")
    func partialSnapshotPreservesAcknowledgement() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Keep the receipt", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_kept", "Keep the receipt"))))
        _ = await completion.value
        store.receive(makeSnapshot(id: alphaID, messages: [message("fmm_kept", "Keep the receipt", status: "processing")]))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_kept"])

        // A mutation acknowledgement carries only the feature; the cached
        // conversation must survive it, and the local row must stay retired.
        store.receive(try receipt(featureID: alphaID, message: nil))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_kept"])
        #expect(!store.isAwaitingSendResolution(featureID: alphaID))
        #expect(store.outgoingMessages(for: alphaID).first?.state == .acceptedAwaitingSnapshot(messageID: "fmm_kept"))
    }

    @Test("A poll before the receipt retires the local row without confirming delivery")
    func pollBeforeReceipt() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Investigate the failure", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }

        // The row is already saved; the delayed receipt still has the older
        // `queued` status captured when the companion appended it.
        store.receive(makeSnapshot(id: alphaID, messages: [message("fmm_seen", "Investigate the failure", status: "processing")]))
        let polled = store.conversationMessages(for: try #require(store.snapshot))
        #expect(polled.map(\.id) == ["fmm_seen"], "The local display row is provisionally replaced, never duplicated")
        #expect(store.outgoingMessages(for: alphaID).first?.state == .pending, "A provisional match never confirms acceptance")
        #expect(store.outgoingMessages(for: alphaID).first?.acceptedStatus == "processing")
        #expect(!store.isAwaitingSendResolution(featureID: alphaID))

        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_seen", "Investigate the failure", status: "queued"))))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: "fmm_seen"))
        #expect(store.outgoingMessages(for: alphaID).first?.acceptedStatus == "processing", "The receipt's older queued status never downgrades the poll")
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_seen"])
    }

    @Test("Identical repeated submissions match rows one-to-one and never deduplicate canonical rows")
    func repeatedIdenticalMessages() async throws {
        let older = message("fmm_old", "Ship it")
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID, messages: [older])])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()

        // First submission: a poll shows one new identical row, matching the
        // one pending submission only.
        let first = try #require(store.beginOutgoingMessage("Ship it", expectedContext: store.operationContext))
        let firstCompletion = Task { await store.completeOutgoingMessage(first) }
        try await waitUntil("first send to suspend") { await client.isHolding(first.requestID) }
        store.receive(makeSnapshot(id: alphaID, messages: [older, message("fmm_new_one", "Ship it", status: "processing")]))
        #expect(store.outgoingMessages(for: alphaID).first?.acceptedStatus == "processing")
        await client.release(first.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_new_one", "Ship it"))))
        #expect(await firstCompletion.value == .acceptedAwaitingSnapshot(messageID: "fmm_new_one"))

        // Second submission: its baseline includes the first new row, so the
        // newer row cannot be consumed twice.
        let second = try #require(store.beginOutgoingMessage("Ship it", expectedContext: store.operationContext))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_old", "fmm_new_one", second.outgoingID])
        let secondCompletion = Task { await store.completeOutgoingMessage(second) }
        try await waitUntil("second send to suspend") { await client.isHolding(second.requestID) }
        store.receive(makeSnapshot(id: alphaID, messages: [
            older,
            message("fmm_new_one", "Ship it", status: "done"),
            message("fmm_new_two", "Ship it", status: "processing"),
        ]))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_old", "fmm_new_one", "fmm_new_two"],
                "Every canonical row remains; only local display rows retire")
        await client.release(second.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_new_two", "Ship it"))))
        #expect(await secondCompletion.value == .acceptedAwaitingSnapshot(messageID: "fmm_new_two"))
        #expect(store.outgoingMessages(for: alphaID).allSatisfy { $0.acceptedStatus != nil })
    }

    @Test("An older receipt without the accepted message presents honestly and confirms nothing")
    func oldEnvelope() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Summarize the change", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: nil)))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: nil))
        #expect(store.isAwaitingSendResolution(featureID: alphaID))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == [handle.outgoingID])

        store.receive(makeSnapshot(id: alphaID, messages: [message("fmm_late", "Summarize the change", status: "processing")]))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == ["fmm_late"])
        #expect(store.outgoingMessages(for: alphaID).first?.state == .acceptedAwaitingSnapshot(messageID: nil),
                "Row wording never confirms the missing receipt identity")
        #expect(store.outgoingMessages(for: alphaID).first?.acceptedStatus == "processing")
        #expect(!store.isAwaitingSendResolution(featureID: alphaID))
    }

    @Test("A rejected send stops speculative work and keeps a recoverable red error")
    func definiteRejection() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Invalid direction", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .failure(APIError.server(status: 400, message: "Invalid direction")))
        #expect(await completion.value == .failed(message: "Invalid direction"))

        #expect(store.sendFailure(for: alphaID)?.failureMessage == "Invalid direction")
        #expect(store.error == nil, "A send failure never masquerades as a refresh error")
        #expect(!store.isSubmitting(featureID: alphaID))
        #expect(!store.isAwaitingSendResolution(featureID: alphaID))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).last?.status == "failed")
        #expect(store.sendFailure(for: alphaID)?.state.isRetryable == true)
        #expect(await client.requests.count == 1, "Nothing resends automatically")

        // A successful poll never erases an unresolved send error.
        store.receive(makeSnapshot(id: alphaID))
        #expect(store.sendFailure(for: alphaID)?.failureMessage == "Invalid direction")
    }

    @Test("An uncertain transport result says delivery could not be confirmed")
    func uncertainTransport() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Retryable direction", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .transport(URLError(.networkConnectionLost)))
        let state = try #require(await completion.value)
        guard case .deliveryUnconfirmed(let failure) = state else {
            Issue.record("Expected an unconfirmed transport result, got \(state)")
            return
        }
        #expect(failure.localizedCaseInsensitiveContains("could not be confirmed"))
        #expect(!failure.localizedCaseInsensitiveContains("rejected"))
        #expect(store.sendFailure(for: alphaID)?.state == state)
        #expect(store.sendFailure(for: alphaID)?.state.isRetryable == true)
    }

    @Test("An explicit retry reuses the original payload, identity, and handle")
    func retryReusesIdentity() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let submission = FirstMateOutgoingMessage.Submission(
            draft: "Keep this direction",
            attachmentIDs: [UUID()],
            quoteIDs: [UUID()],
            containsDictation: true
        )
        let handle = try #require(store.beginOutgoingMessage("Keep this direction", expectedContext: store.operationContext, submission: submission))
        let firstAttempt = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("first send to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .transport(URLError(.timedOut)))
        #expect(await firstAttempt.value == .deliveryUnconfirmed(
            message: "Delivery could not be confirmed. \(URLError(.timedOut).localizedDescription)"
        ))
        #expect(store.discardOutgoingMessage(handle) == submission, "The frozen material is recoverable")
        #expect(store.sendFailure(for: alphaID) == nil)

        // A fresh submission after an explicit discard gets a fresh identity.
        let fresh = try #require(store.beginOutgoingMessage("Keep this direction", expectedContext: store.operationContext, submission: submission))
        #expect(fresh.requestID != handle.requestID)
        let freshAttempt = Task { await store.completeOutgoingMessage(fresh) }
        try await waitUntil("fresh send to suspend") { await client.isHolding(fresh.requestID) }
        await client.release(fresh.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_fresh", "Keep this direction"))))
        #expect(await freshAttempt.value == .acceptedAwaitingSnapshot(messageID: "fmm_fresh"))

        // A kept failure retries in place with the same identity and payload.
        let kept = try #require(store.beginOutgoingMessage("Keep this direction", expectedContext: store.operationContext, submission: submission))
        let failed = Task { await store.completeOutgoingMessage(kept) }
        try await waitUntil("kept send to suspend") { await client.isHolding(kept.requestID) }
        await client.release(kept.requestID, with: .failure(APIError.server(status: 409, message: "Conflict")))
        #expect(await failed.value == .failed(message: "Conflict"))

        let retry = Task { await store.retryOutgoingMessage(kept) }
        try await waitUntil("retry to suspend") { await client.isHolding(kept.requestID) }
        await client.release(kept.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_retried", "Keep this direction"))))
        #expect(await retry.value == .acceptedAwaitingSnapshot(messageID: "fmm_retried"))

        let requests = await client.requests.filter { $0.requestID == kept.requestID }
        #expect(requests.count == 2)
        #expect(requests[0].text == requests[1].text)
        #expect(store.outgoingMessage(kept)?.submission == submission)
    }

    @Test("A retry repeats the lead context frozen at submission time")
    func leadContextFrozen() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID, kind: "lead")])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.leadFeatureID == alphaID)
        let submitted = FirstMateLeadContext(machines: [.init(name: "Alpha Mac", features: [])])
        let newer = FirstMateLeadContext(machines: [.init(name: "Beta Mac", features: [])])
        store.leadContextProvider = { submitted }
        let handle = try #require(store.beginOutgoingMessage("Ask the lead", expectedContext: store.operationContext))
        #expect(store.outgoingMessages(for: alphaID).first?.leadContext == submitted)
        store.leadContextProvider = { newer }

        let firstAttempt = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("lead send to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .transport(URLError(.cannotConnectToHost)))
        _ = await firstAttempt.value
        let retry = Task { await store.retryOutgoingMessage(handle) }
        try await waitUntil("lead retry to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, kind: "lead", message: message("fmm_lead", "Ask the lead"))))
        _ = await retry.value

        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.leadContext == submitted })
    }

    @Test("A late completion stays with its original feature after a selection change")
    func selectionChangeIsolation() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID), makeSnapshot(id: betaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.selectedFeatureID == alphaID)
        let handle = try #require(store.beginOutgoingMessage("Alpha direction", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }

        store.select(betaID)
        #expect(store.selectedFeatureID == betaID)
        #expect(store.isSubmitting(featureID: betaID) == false)
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_alpha", "Alpha direction"))))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: "fmm_alpha"))

        #expect(store.outgoingMessages(for: betaID).isEmpty)
        #expect(store.sendFailure(for: betaID) == nil)
        #expect(store.outgoingMessages(for: alphaID).count == 1)
        #expect(store.conversationMessages(for: makeSnapshot(id: betaID)).isEmpty)
        #expect(store.conversationMessages(for: try #require(store.snapshot(for: handle.context))).map(\.id) == [handle.outgoingID])
    }

    @Test("A reconnect clears scoped optimistic state and fences late responses")
    func lifecycleIsolation() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Do not land after reconnect", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }

        store.configure(client: nil, demo: true)
        #expect(store.outgoingMessages(for: alphaID).isEmpty)
        #expect(store.sendFailure(for: alphaID) == nil)
        #expect(store.outgoingMessage(handle) == nil)
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_late", "Do not land after reconnect"))))
        #expect(await completion.value == nil)
        #expect(store.outgoingMessages(for: alphaID).isEmpty)
        #expect(store.isDemo)
    }

    @Test("Only a ready destination can reserve a submission")
    func beginValidation() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID), makeSnapshot(id: betaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        #expect(store.beginOutgoingMessage("   \n", expectedContext: context) == nil)
        #expect(store.outgoingMessages(for: alphaID).isEmpty)
        let first = try #require(store.beginOutgoingMessage("Direction", expectedContext: context))
        #expect(store.beginOutgoingMessage("Second direction", expectedContext: context) == nil, "A second in-flight submission never duplicates")

        let otherStore = FirstMateStore()
        otherStore.configure(client: client, demo: false)
        await otherStore.refresh()
        #expect(store.beginOutgoingMessage("Direction", expectedContext: otherStore.operationContext) == nil, "A foreign lifecycle can never reserve here")

        store.receive(makeSnapshot(id: alphaID, status: "completed"))
        #expect(store.beginOutgoingMessage("Closed feature direction", expectedContext: context) == nil)
        #expect(store.outgoingMessages(for: alphaID).map(\.id) == [first.outgoingID])
    }

    @Test("A delayed or failed follow-up refresh never changes an accepted submission")
    func delayedRefreshDoesNotDelayAcceptance() async throws {
        let client = DeferredOutgoingFirstMateClient(snapshots: [makeSnapshot(id: alphaID)])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let handle = try #require(store.beginOutgoingMessage("Resolve without waiting", expectedContext: store.operationContext))
        let completion = Task { await store.completeOutgoingMessage(handle) }
        try await waitUntil("send request to suspend") { await client.isHolding(handle.requestID) }
        await client.release(handle.requestID, with: .snapshot(try receipt(featureID: alphaID, message: message("fmm_fast", "Resolve without waiting"))))
        #expect(await completion.value == .acceptedAwaitingSnapshot(messageID: "fmm_fast"))

        // A stalled feature refresh cannot roll back acceptance or presentation.
        await client.holdFeatureFetch(true)
        let refresh = Task { await store.refreshFeature(handle.context) }
        try await waitUntil("follow-up refresh to suspend") { await client.isHoldingFeatureFetch }
        #expect(store.outgoingMessages(for: alphaID).first?.state == .acceptedAwaitingSnapshot(messageID: "fmm_fast"))
        #expect(store.conversationMessages(for: try #require(store.snapshot)).map(\.id) == [handle.outgoingID])
        await client.releaseFeatureFetch()
        await refresh.value

        // A failed refresh only records the ordinary refresh error.
        await client.holdFeatureFetch(false)
        await client.setFeatureFetchError(URLError(.cannotConnectToHost))
        await store.refreshFeature(handle.context)
        #expect(store.error != nil)
        #expect(store.outgoingMessages(for: alphaID).first?.state == .acceptedAwaitingSnapshot(messageID: "fmm_fast"))
        #expect(store.isAwaitingSendResolution(featureID: alphaID))
    }

    private enum WaitError: Error { case timedOut(String) }

    private func waitUntil(_ description: String, condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw WaitError.timedOut(description) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private let alphaID = "feature:alpha"
    private let betaID = "feature:beta"

    private func makeFeature(id: String, status: String = "running", kind: String? = nil) -> FirstMateFeature {
        FirstMateFeature(
            id: id,
            title: "Synthetic feature",
            goal: "Exercise optimistic presentation",
            cwd: "/workspace/synthetic",
            status: status,
            currentVisitID: nil,
            revision: 1,
            createdAt: "2026-01-15T14:30:00Z",
            updatedAt: "2026-01-15T14:30:00Z",
            workItemID: nil,
            kind: kind
        )
    }

    private func makeSnapshot(id: String, status: String = "running", kind: String? = nil, messages: [FirstMateMessage] = []) -> FirstMateSnapshot {
        var value = FirstMateSnapshot(feature: makeFeature(id: id, status: status, kind: kind))
        value.messages = messages
        return value
    }

    private func message(
        _ id: String,
        _ text: String,
        featureID: String? = nil,
        role: String = "user",
        status: String = "queued"
    ) -> FirstMateMessage {
        FirstMateMessage(
            id: id,
            featureID: featureID ?? alphaID,
            role: role,
            text: text,
            status: status,
            createdAt: "2026-01-15T14:31:00Z"
        )
    }

    /// The real 202 receipt shape: feature plus an optional singular accepted
    /// message, with no visits/messages/events arrays.
    private func receipt(featureID: String, kind: String? = nil, message accepted: FirstMateMessage?) throws -> FirstMateSnapshot {
        var object: [String: Any] = [
            "ok": true,
            "feature": try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeFeature(id: featureID, kind: kind))),
        ]
        if let accepted {
            object["message"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(accepted))
        }
        return try JSONDecoder().decode(FirstMateSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// A synthetic companion whose message sends suspend until the test releases
/// them, with configurable refresh delays and failures. Every wait is driven
/// by the test polling a bounded condition, so ordering is deterministic.
private actor DeferredOutgoingFirstMateClient: FirstMateClient {
    enum SendOutcome: Sendable {
        case snapshot(FirstMateSnapshot)
        case failure(APIError)
        case transport(URLError)
    }

    struct SendRequest: Equatable, Sendable {
        var featureID: String
        var text: String
        var requestID: String
        var leadContext: FirstMateLeadContext?
    }

    private var snapshots: [FirstMateSnapshot]
    private(set) var requests: [SendRequest] = []
    private var held: [String: CheckedContinuation<SendOutcome, Error>] = [:]
    private var ready: [String: SendOutcome] = [:]
    private var featureFetchError: Error?
    private var holdsFeatureFetch = false
    private var featureFetchContinuation: CheckedContinuation<Void, Never>?
    private var featureFetchReleased = false

    init(snapshots: [FirstMateSnapshot]) {
        self.snapshots = snapshots
    }

    var isHoldingFeatureFetch: Bool { featureFetchContinuation != nil }

    func isHolding(_ requestID: String) -> Bool { held[requestID] != nil }
    func setFeatureFetchError(_ error: Error?) { featureFetchError = error }
    func holdFeatureFetch(_ hold: Bool) { holdsFeatureFetch = hold }

    func releaseFeatureFetch() {
        if let featureFetchContinuation {
            self.featureFetchContinuation = nil
            featureFetchContinuation.resume()
        } else {
            featureFetchReleased = true
        }
    }

    func release(_ requestID: String, with outcome: SendOutcome) {
        guard let continuation = held.removeValue(forKey: requestID) else {
            ready[requestID] = outcome
            return
        }
        continuation.resume(returning: outcome)
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-lead-v1"])
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures(scope: .active)
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        .init(ok: true, features: snapshots.map(\.feature))
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        if holdsFeatureFetch {
            await withCheckedContinuation { featureFetchContinuation = $0 }
            if featureFetchReleased { featureFetchReleased = false }
        }
        if let featureFetchError { throw featureFetchError }
        guard let snapshot = snapshots.first(where: { $0.feature.id == id }) else {
            throw APIError.server(status: 404, message: "Not found")
        }
        return snapshot
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        try await performSend(featureID: featureID, text: text, requestID: requestID, leadContext: nil)
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        throw APIError.invalidResponse
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        throw APIError.invalidResponse
    }

    func sendFirstMateMessage(
        featureID: String,
        text: String,
        requestID: String,
        context: FirstMateLeadContext
    ) async throws -> FirstMateSnapshot {
        try await performSend(featureID: featureID, text: text, requestID: requestID, leadContext: context)
    }

    private func performSend(
        featureID: String,
        text: String,
        requestID: String,
        leadContext: FirstMateLeadContext?
    ) async throws -> FirstMateSnapshot {
        requests.append(SendRequest(featureID: featureID, text: text, requestID: requestID, leadContext: leadContext))
        let outcome: SendOutcome
        if let queued = ready.removeValue(forKey: requestID) {
            outcome = queued
        } else {
            outcome = try await withCheckedThrowingContinuation { held[requestID] = $0 }
        }
        switch outcome {
        case .snapshot(let value): return value
        case .failure(let error): throw error
        case .transport(let error): throw error
        }
    }
}
