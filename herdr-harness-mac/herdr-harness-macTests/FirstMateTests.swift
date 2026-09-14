import Foundation
import Testing
@testable import herdr_harness_mac

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
        #expect(snapshot.sessions(for: nil).count == 2)
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

    @Test("First Mate is a persistent shell destination outside the crowded picker")
    func navigationRecord() throws {
        let record = try #require(HerdrDestinationRecord(.firstMate))
        #expect(record.destination == .firstMate)
        #expect(HerdrDetailScope.pickerSelection(for: .firstMate) == nil)
    }
}

private actor FirstMateTestClient: FirstMateClient {
    let unsupported: Bool
    let paginated: Bool
    let holdEarlier: Bool
    private var earlierContinuation: CheckedContinuation<Void, Never>?
    var isWaitingForEarlier: Bool { earlierContinuation != nil }
    var messageRequests: [String] = []
    var lastSessionID: String?
    init(unsupported: Bool = false, paginated: Bool = false, holdEarlier: Bool = false) {
        self.unsupported = unsupported
        self.paginated = paginated
        self.holdEarlier = holdEarlier
    }
    func releaseEarlier() { earlierContinuation?.resume(); earlierContinuation = nil }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        if unsupported { throw APIError.server(status: 404, message: "Not found") }
        return .init(ok: true, features: [FirstMateDemo.features(step: 0)[0].feature])
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { FirstMateDemo.features(step: 0)[0] }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        messageRequests.append(requestID)
        if messageRequests.count == 1 { throw URLError(.networkConnectionLost) }
        return FirstMateDemo.features(step: 1)[0]
    }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { FirstMateDemo.features(step: 0)[0] }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        .init(ok: true, document: FirstMateDemo.features(step: 0)[0].documents[0])
    }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        lastSessionID = id
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
