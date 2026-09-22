import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate native contract", .serialized)
@MainActor
struct FirstMateTests {
    @Test("Snake-case snapshots retain exact session and document ownership")
    func decodeSnapshot() throws {
        let original = FirstMateDemo.features(step: 3)[0]
        let data = try JSONEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("native_session_id"))
        #expect(json.contains("assignment_id"))
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: data)
        #expect(decoded == original)
        let reviewers = decoded.agents(for: "demo-review")
        #expect(reviewers.count == 7)
        #expect(Set(reviewers.compactMap(\.nativeSessionID)).count == 7)
        #expect(decoded.documents(for: "demo-plan").count == 3)
        for document in decoded.documents {
            #expect(decoded.author(of: document)?.nativeSessionID == document.nativeSessionID)
        }
        #expect(!decoded.visits.contains { ["checkpoint", "handoff"].contains($0.stageKey) })
    }

    @Test("Stale snapshots cannot overwrite a newer revision")
    func ignoresStaleSnapshot() {
        let store = FirstMateStore()
        let newer = FirstMateDemo.features(step: 4)[0]
        store.receive(newer)
        store.receive(FirstMateDemo.features(step: 1)[0])
        store.select(newer.feature.id)
        #expect(store.snapshot == newer)
    }

    @Test("Evidence opens its producing session after an assignment moves to a successor")
    func retainedDocumentProducer() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        let document = try #require(snapshot.documents.first)
        let index = try #require(snapshot.assignments.firstIndex { $0.id == document.assignmentID })
        snapshot.assignments[index].nativeSessionID = "successor-session"
        #expect(snapshot.author(of: document)?.nativeSessionID == document.nativeSessionID)
        #expect(snapshot.author(of: document)?.nativeSessionID != "successor-session")
    }

    @Test("Feature-only mutation acknowledgments preserve the journal and update status")
    func partialMutationResponse() throws {
        let store = FirstMateStore()
        let original = FirstMateDemo.features(step: 3)[0]
        store.receive(original)
        store.select(original.feature.id)
        var feature = original.feature
        feature.status = "paused"
        let featureData = try JSONEncoder().encode(feature)
        let object = try JSONSerialization.jsonObject(with: featureData)
        let response = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": object])
        let acknowledgment = try JSONDecoder().decode(FirstMateSnapshot.self, from: response)
        #expect(!acknowledgment.hasDetails)
        store.receive(acknowledgment)
        #expect(store.snapshot?.feature.status == "paused")
        #expect(store.snapshot?.assignments == original.assignments)
        #expect(store.snapshot?.messages == original.messages)
        #expect(store.snapshot?.documents == original.documents)
    }

    @Test("Partial acknowledgements distinguish explicit session rotation from omitted legacy metadata")
    func partialAcknowledgementSessionPresence() throws {
        let store = FirstMateStore()
        var original = FirstMateDemo.features(step: 0)[0]
        original.feature.nativeSessionID = "session-before-rotation"
        original.feature.coordinatorContext = .init(
            nativeSessionID: "session-before-rotation",
            status: .measured,
            tokens: 42_000,
            contextWindow: 200_000,
            handoffTargetTokens: 160_000
        )
        store.receive(original)
        store.select(original.feature.id)

        let encoded = try JSONEncoder().encode(original.feature)
        var featureObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        featureObject["revision"] = original.feature.revision + 1
        featureObject["native_session_id"] = NSNull()
        featureObject.removeValue(forKey: "coordinator_context")
        let explicitNullData = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": featureObject])
        let explicitNull = try JSONDecoder().decode(FirstMateSnapshot.self, from: explicitNullData)
        #expect(explicitNull.feature.includesNativeSessionID)
        store.receive(explicitNull)
        #expect(store.snapshot?.feature.nativeSessionID == nil)
        #expect(store.snapshot?.feature.coordinatorContext == nil)

        let legacyStore = FirstMateStore()
        legacyStore.receive(original)
        legacyStore.select(original.feature.id)
        featureObject.removeValue(forKey: "native_session_id")
        featureObject["revision"] = original.feature.revision + 2
        let omittedData = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": featureObject])
        let omitted = try JSONDecoder().decode(FirstMateSnapshot.self, from: omittedData)
        #expect(!omitted.feature.includesNativeSessionID)
        legacyStore.receive(omitted)
        #expect(legacyStore.snapshot?.feature.nativeSessionID == "session-before-rotation")
        #expect(legacyStore.snapshot?.feature.coordinatorContext?.tokens == 42_000)
    }

    @Test("Delayed partial acknowledgements cannot resurrect rotated coordinator identity")
    func delayedPartialAcknowledgementSessionIdentity() throws {
        let store = FirstMateStore()
        var original = FirstMateDemo.features(step: 0)[0]
        original.feature.updatedAt = "2030-01-01T12:00:00Z"
        original.feature.nativeSessionID = "session-old"
        original.feature.coordinatorContext = .init(
            nativeSessionID: "session-old",
            status: .measured,
            tokens: 40_000,
            contextWindow: 200_000,
            handoffTargetTokens: 160_000
        )
        store.receive(original)
        store.select(original.feature.id)

        var successor = original
        successor.feature.updatedAt = "2030-01-01T12:02:00Z"
        successor.feature.nativeSessionID = "session-successor"
        successor.feature.coordinatorContext = .init(
            nativeSessionID: "session-successor",
            status: .measured,
            tokens: 2_000,
            contextWindow: 200_000,
            handoffTargetTokens: 160_000
        )
        store.receive(successor)

        var delayedFeature = original.feature
        delayedFeature.updatedAt = "2030-01-01T12:01:00Z"
        delayedFeature.status = "paused"
        let delayedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(delayedFeature))
        let delayedData = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": delayedObject])
        let delayed = try JSONDecoder().decode(FirstMateSnapshot.self, from: delayedData)
        #expect(!delayed.hasDetails)
        store.receive(delayed)
        #expect(store.snapshot?.feature.status == "paused")
        #expect(store.snapshot?.feature.updatedAt == "2030-01-01T12:02:00Z")
        #expect(store.snapshot?.feature.nativeSessionID == "session-successor")
        #expect(store.snapshot?.feature.coordinatorContext?.nativeSessionID == "session-successor")

        var cleared = successor
        cleared.feature.updatedAt = "2030-01-01T12:03:00Z"
        cleared.feature.nativeSessionID = nil
        cleared.feature.coordinatorContext = nil
        store.receive(cleared)
        store.receive(delayed)
        #expect(store.snapshot?.feature.updatedAt == "2030-01-01T12:03:00Z")
        #expect(store.snapshot?.feature.nativeSessionID == nil)
        #expect(store.snapshot?.feature.coordinatorContext == nil)

        var newestFeature = cleared.feature
        newestFeature.updatedAt = "2030-01-01T12:04:00Z"
        newestFeature.nativeSessionID = "session-newest"
        newestFeature.coordinatorContext = .init(
            nativeSessionID: "session-newest",
            status: .measured,
            tokens: 1_000,
            contextWindow: 200_000,
            handoffTargetTokens: 160_000
        )
        let newestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(newestFeature))
        let newestData = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": newestObject])
        store.receive(try JSONDecoder().decode(FirstMateSnapshot.self, from: newestData))
        #expect(store.snapshot?.feature.nativeSessionID == "session-newest")
        #expect(store.snapshot?.feature.coordinatorContext?.nativeSessionID == "session-newest")
    }

    @Test("Feature drafts stay separate and a host change clears sensitive state")
    func draftAndConnectionIsolation() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let first = store.features[0].id
        let second = store.features[1].id
        store.draft = "First feature direction"
        store.select(second)
        #expect(store.draft.isEmpty)
        store.draft = "Second feature direction"
        store.select(first)
        #expect(store.draft == "First feature direction")
        store.configure(client: nil, demo: false)
        #expect(store.features.isEmpty)
        #expect(store.draft.isEmpty)
        #expect(store.snapshot == nil)
    }

    @Test("A captured composer binding cannot write into a newly selected feature")
    func capturedComposerBinding() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let first = store.features[0].id
        let second = store.features[1].id
        let firstContext = store.operationContext
        store.setComposerDraft("Original feature", for: firstContext)
        store.select(second)
        store.setComposerDraft("Late original edit", for: firstContext)
        #expect(store.draft.isEmpty)
        store.setComposerDraft("Second feature", for: store.operationContext)
        store.select(first)
        #expect(store.draft == "Late original edit")
    }

    @Test("A failed message retry reuses its request ID and preserves the draft")
    func messageRetryIsIdempotent() async {
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        store.draft = "Proceed with implementation"
        await store.send()
        #expect(store.draft == "Proceed with implementation")
        #expect(store.error != nil)
        await store.send()
        let requests = await client.messageRequests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(store.draft.isEmpty)
    }

    @Test("An older companion produces upgrade guidance without demo data")
    func olderServer() async {
        let client = FirstMateTestClient(unsupported: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.unsupported)
        #expect(store.error?.contains("first-mate-v1") == true)
        #expect(store.features.isEmpty)
        #expect(!store.isDemo)
    }

    @Test("Archive support is capability-gated and active lists hide archived features")
    func archiveState() async {
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let id = store.features[0].id
        store.draft = "Retain this archived feature draft"
        #expect(store.archiveSupported)
        #expect(await store.setArchived(featureID: id, archived: true, reason: .testSynthetic))
        #expect(store.features.isEmpty)
        #expect(store.draft.isEmpty)
        store.showArchived = true
        await store.refresh()
        #expect(store.archivedFeatures.map(\.id) == [id])
        #expect(store.archivedFeatures[0].archiveReason == FirstMateArchiveReason.testSynthetic.rawValue)
        #expect(store.draft == "Retain this archived feature draft")
        #expect(await store.setArchived(featureID: id, archived: false))
        #expect(store.activeFeatures.map(\.id) == [id])
        #expect(await client.archiveRequests == ["archive", "unarchive"])

        let older = FirstMateTestClient(archiveCapability: false)
        store.configure(client: older, demo: false)
        await store.refresh()
        #expect(!store.archiveSupported)
        #expect(!(await store.setArchived(featureID: id, archived: true)))
        #expect(store.error?.contains("Update this companion") == true)
        #expect(await older.archiveRequests.isEmpty)
    }

    @Test("Opening a resource requests its saved session identity")
    func opensExactSession() async throws {
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let snapshot = FirstMateDemo.features(step: 3)[0]
        store.receive(snapshot)
        store.select(snapshot.feature.id)
        let reviewer = try #require(snapshot.agents(for: "demo-review").last)
        await store.open(.session(reviewer))
        #expect(await client.lastSessionID == reviewer.nativeSessionID)
        #expect(store.resourceText.contains("Saved review result"))
    }

    @Test("Retained sessions without documents and coordinator predecessors remain accessible")
    func completeSessionLineage() async throws {
        let snapshot = FirstMateDemo.features(step: 5)[0]
        let predecessor = try #require(snapshot.sessions(for: "demo-successor").first)
        #expect(predecessor.nativeSessionID == "demo-session-predecessor")
        #expect(!snapshot.documents.contains { $0.nativeSessionID == predecessor.nativeSessionID })
        #expect(snapshot.coordinatorSessions.count == 2)
        #expect(snapshot.advisorSessions.count == 1)
        #expect(snapshot.sessions(for: nil).count == 3)
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.receive(snapshot)
        store.select(snapshot.feature.id)
        await store.open(.history(predecessor))
        #expect(await client.lastSessionID == predecessor.nativeSessionID)
        let presentation = try #require(store.resourcePresentation?.id)
        let successor = try #require(snapshot.sessions(for: "demo-successor").last)
        await store.open(.history(successor))
        #expect(store.resourcePresentation?.id == presentation)
        #expect(store.openedResource?.nativeSessionID == successor.nativeSessionID)
    }

    @Test("Carried assignments appear in revised stages without changing producer provenance")
    func carriedVisitMembership() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.assignments[0].visitIDs = ["demo-plan", "revised-plan"]
        #expect(snapshot.agents(for: "revised-plan").count == 1)
        #expect(snapshot.assignments[0].visitID == "demo-plan")
        let evidence = try #require(snapshot.documents(for: "revised-plan").first)
        #expect(evidence.visitID == "demo-plan")
        #expect(snapshot.author(of: evidence)?.nativeSessionID == evidence.nativeSessionID)
    }

    @Test("Earlier transcript pages prepend without losing the current session identity")
    func transcriptPagination() async throws {
        let client = FirstMateTestClient(paginated: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let agent = FirstMateDemo.features(step: 0)[0].assignments[0]
        await store.open(.session(agent))
        #expect(store.sessionNextBefore == 2)
        #expect(store.sessionLoadedMessages == 1)
        await store.loadEarlierSessionMessages()
        #expect(store.sessionNextBefore == nil)
        #expect(store.sessionLoadedMessages == 3)
        #expect(store.sessionTotalMessages == 3)
        #expect(store.resourceText.hasPrefix("User\nOriginal direction"))
        #expect(store.resourceText.contains("Saved review result"))
    }

    @Test("A delayed older page cannot replace a newly selected session")
    func staleTranscriptPage() async throws {
        let client = FirstMateTestClient(paginated: true, holdEarlier: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let agents = FirstMateDemo.features(step: 0)[0].assignments
        await store.open(.session(agents[0]))
        let loading = Task { await store.loadEarlierSessionMessages() }
        while !(await client.isWaitingForEarlier) { await Task.yield() }
        await store.open(.session(agents[1]))
        await client.releaseEarlier()
        await loading.value
        #expect(store.openedResource?.nativeSessionID == agents[1].nativeSessionID)
        #expect(store.sessionLoadedMessages == 1)
        #expect(!store.resourceText.contains("Original direction"))
    }

    @Test("A delayed host response cannot replace the newly configured host")
    func delayedHostResponse() async {
        let client = FirstMateTestClient(holdList: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let refresh = Task { await store.refresh() }
        while !(await client.isWaitingForList) { await Task.yield() }
        store.configure(client: nil, demo: true)
        store.draft = "Direction for the newly selected host"
        await client.releaseList()
        await refresh.value
        #expect(store.isDemo)
        #expect(store.features.count == 2)
        #expect(store.draft == "Direction for the newly selected host")
        #expect(store.error == nil)
        #expect(!store.isRefreshing)
    }

    @Test("A mismatched mutation response preserves direction for a safe retry")
    func mismatchedMutationResponse() async {
        let client = FirstMateTestClient(mismatchedMutation: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        store.draft = "Keep this direction on the original feature"
        // The first attempt simulates an interrupted connection.
        await store.send()
        await store.send()
        #expect(store.error != nil)
        #expect(store.features.count == 1)
        #expect(store.selectedFeatureID == "demo-session-continuity")
        #expect(store.draft == "Keep this direction on the original feature")
    }

    @Test("A response for a different native session is rejected")
    func rejectsMismatchedSession() async throws {
        let client = FirstMateTestClient(mismatchedSession: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let agent = FirstMateDemo.features(step: 0)[0].assignments[0]
        await store.open(.session(agent))
        #expect(store.resourceError != nil)
        #expect(store.resourceText.isEmpty)
        #expect(store.sessionLoadedMessages == 0)
        store.configure(client: nil, demo: false)
        #expect(store.resourceError == nil)
        #expect(!store.resourceLoading)
    }

    @Test("A queued send cannot submit a newly selected feature's draft")
    func queuedSendRetainsFeatureIntent() async {
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let first = FirstMateDemo.features(step: 0)[0].feature.id
        let second = FirstMateDemo.features(step: 0)[1]
        store.receive(second)
        store.draft = "Direction intended for the first feature"
        let context = store.operationContext
        let text = store.draft
        let sending = Task { await store.send(expectedContext: context, expectedText: text) }
        store.select(second.feature.id)
        store.draft = "A separate unsent draft for the second feature"
        await sending.value
        #expect(await client.messageRequests.isEmpty)
        #expect(store.draft == "A separate unsent draft for the second feature")
        store.select(first)
        #expect(store.draft == text)
    }

    @Test("An edited draft is not submitted by an earlier queued send")
    func queuedSendRetainsTextIntent() async {
        let client = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        store.draft = "Plan the change"
        let context = store.operationContext
        let text = store.draft
        let sending = Task { await store.send(expectedContext: context, expectedText: text) }
        store.draft = "Plan the change, and wait for my review"
        await sending.value
        #expect(await client.messageRequests.isEmpty)
        #expect(store.draft == "Plan the change, and wait for my review")
    }

    @Test("Queued mutations cannot follow an identical feature ID onto another host")
    func queuedMutationsRetainHostIntent() async {
        let previous = FirstMateTestClient()
        let replacement = FirstMateTestClient()
        let store = FirstMateStore()
        store.configure(client: previous, demo: false)
        await store.refresh()
        store.draft = "Direction for the previous host"
        let context = store.operationContext
        let text = store.draft
        let sending = Task { await store.send(expectedContext: context, expectedText: text) }
        let pausing = Task { await store.perform("pause", expectedContext: context) }
        let creating = Task {
            await store.create(title: "Previous host feature", goal: "Keep the original host", cwd: "/workspace/sample-app",
                               requestID: "original-host-create", expectedContext: context)
        }
        // The replacement deliberately has the same feature ID and draft text.
        store.configure(client: replacement, demo: false)
        let replacementSnapshot = FirstMateDemo.features(step: 0)[0]
        store.receive(replacementSnapshot)
        store.select(replacementSnapshot.feature.id)
        store.draft = text
        await sending.value
        await pausing.value
        #expect(await creating.value == false)
        #expect(await previous.messageRequests.isEmpty)
        #expect(await previous.actionRequests.isEmpty)
        #expect(await previous.creationRequests.isEmpty)
        #expect(await replacement.messageRequests.isEmpty)
        #expect(await replacement.actionRequests.isEmpty)
        #expect(await replacement.creationRequests.isEmpty)
        #expect(store.draft == text)
    }

    #if os(macOS)
    @Test("First Mate is a persistent shell destination outside the crowded picker")
    func navigationRecord() throws {
        let record = try #require(HerdrDestinationRecord(.firstMate))
        #expect(record.destination == .firstMate)
        #expect(HerdrDetailScope.pickerSelection(for: .firstMate) == nil)
    }
    #endif
}

private actor FirstMateTestClient: FirstMateClient {
    let unsupported: Bool
    let paginated: Bool
    let holdEarlier: Bool
    let holdList: Bool
    let mismatchedMutation: Bool
    let mismatchedSession: Bool
    let archiveCapability: Bool
    private var isArchived = false
    private var listContinuation: CheckedContinuation<Void, Never>?
    var isWaitingForList: Bool { listContinuation != nil }
    private var earlierContinuation: CheckedContinuation<Void, Never>?
    var isWaitingForEarlier: Bool { earlierContinuation != nil }
    var messageRequests: [String] = []
    var actionRequests: [String] = []
    var creationRequests: [String] = []
    var archiveRequests: [String] = []
    var lastSessionID: String?
    init(unsupported: Bool = false, paginated: Bool = false, holdEarlier: Bool = false, holdList: Bool = false, mismatchedMutation: Bool = false, mismatchedSession: Bool = false, archiveCapability: Bool = true) {
        self.unsupported = unsupported
        self.paginated = paginated
        self.holdEarlier = holdEarlier
        self.holdList = holdList
        self.mismatchedMutation = mismatchedMutation
        self.mismatchedSession = mismatchedSession
        self.archiveCapability = archiveCapability
    }
    func releaseList() { listContinuation?.resume(); listContinuation = nil }
    func releaseEarlier() { earlierContinuation?.resume(); earlierContinuation = nil }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        if unsupported { throw APIError.server(status: 404, message: "Not found") }
        return .init(ok: true, capabilities: archiveCapability ? ["first-mate-v1", "first-mate-archive-v1"] : ["first-mate-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures(scope: .active)
    }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        if unsupported { throw APIError.server(status: 404, message: "Not found") }
        if holdList { await withCheckedContinuation { listContinuation = $0 } }
        var feature = FirstMateDemo.features(step: 0)[0].feature
        feature.archivedAt = isArchived ? FirstMateDemo.timestamp : nil
        feature.archiveReason = isArchived ? FirstMateArchiveReason.testSynthetic.rawValue : nil
        return .init(ok: true, features: scope == .active && isArchived ? [] : [feature])
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.archivedAt = isArchived ? FirstMateDemo.timestamp : nil
        snapshot.feature.archiveReason = isArchived ? FirstMateArchiveReason.testSynthetic.rawValue : nil
        return snapshot
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        creationRequests.append(requestID)
        return FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        messageRequests.append(requestID)
        if messageRequests.count == 1 { throw URLError(.networkConnectionLost) }
        if mismatchedMutation { return FirstMateDemo.features(step: 1)[1] }
        return FirstMateDemo.features(step: 1)[0]
    }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        actionRequests.append(requestID)
        return FirstMateDemo.features(step: 0)[0]
    }
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot {
        archiveRequests.append(archived ? "archive" : "unarchive")
        isArchived = archived
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.archivedAt = archived ? FirstMateDemo.timestamp : nil
        snapshot.feature.archiveReason = archived ? reason?.rawValue : nil
        return snapshot
    }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        .init(ok: true, document: FirstMateDemo.features(step: 0)[0].documents[0])
    }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        lastSessionID = id
        if mismatchedSession { return .init(ok: true, nativeSessionID: "wrong-session", messages: [.init(role: "assistant", text: "Wrong session content")]) }
        if paginated {
            if before != nil {
                if holdEarlier { await withCheckedContinuation { earlierContinuation = $0 } }
                return .init(ok: true, nativeSessionID: id, messages: [.init(role: "user", text: "Original direction"), .init(role: "assistant", text: "Earlier result")], nextBefore: nil, totalMessages: 3)
            }
            return .init(ok: true, nativeSessionID: id, messages: [.init(role: "assistant", text: "Saved review result")], nextBefore: 2, totalMessages: 3)
        }
        return .init(ok: true, nativeSessionID: id, messages: [.init(role: "assistant", text: "Saved review result")])
    }
}
