import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate responsive navigation")
@MainActor
struct FirstMatePerformanceRegressionTests {
    @Test("Fleet polls ignore assessment timestamps but publish changed verdicts")
    func fleetVerificationTicks() async {
        var feature = ChatFixtures.feature("f1")
        feature.verification = FirstMateVerification(status: .partiallyVerified, computedAt: "2030-01-01T00:00:00Z")
        let client = SyntheticChatFleetClient(features: [feature])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        let revision = index.contentRevision
        feature.verification?.computedAt = "2030-01-01T00:00:10Z"
        client.features = .success([feature])
        await index.refresh(lifecycle: lifecycle)
        #expect(index.contentRevision == revision)
        feature.verification?.status = .failed
        client.features = .success([feature])
        await index.refresh(lifecycle: lifecycle)
        #expect(index.contentRevision > revision)
        #expect(index.hosts.first?.features.first?.verification?.status == .failed)
    }

    @Test("Switching bypasses an uncancellable old response on the same or another host", arguments: [false, true])
    func switchWhileReading(otherHost: Bool) async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1"), ChatFixtures.feature("f2")])
        let gate = FirstMatePerformanceReadGate()
        client.beforeFeature = { id in if id == "f1" { await gate.wait() } }
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: false), shell: ChatFixtures.shell(),
            configuration: { ServerConfiguration(urlString: "https://\($0).example.invalid", token: "synthetic") },
            makeClient: { _ in client }, fleetSources: { [] })
        session.select(.feature(.init(machineID: "alpha", featureID: "f1")))
        let task = Task { await session.run() }
        defer { task.cancel() }
        try await ChatFixtures.waitUntil("old read started") { client.featureCalls == 1 }
        let oldStore = try #require(session.selectedStore)
        session.select(.feature(.init(machineID: otherHost ? "beta" : "alpha", featureID: "f2")))
        try await ChatFixtures.waitUntil("new chat opens while the old transport is still blocked") {
            session.selectedSnapshot?.feature.id == "f2"
        }
        if otherHost { #expect(!oldStore.controlAvailable) }
        #expect(session.selectedStore?.controlAvailable == true)
        #expect(client.featureListCalls == 0)
        await gate.release()
        task.cancel()
        await task.value
        #expect(session.selectedSnapshot?.feature.id == "f2")
        #expect(session.selectedStore?.controlAvailable == false)
    }

    @Test("Leaving the lead during its open cannot steal the new selection")
    func supersededLeadOpen() async throws {
        let client = SyntheticChatFleetClient()
        let gate = FirstMatePerformanceReadGate()
        client.beforeEnsure = { await gate.wait() }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let task = Task { await store.openLead() }
        try await ChatFixtures.waitUntil("lead open started") { client.ensureCalls == 1 }
        store.select("another-feature")
        await gate.release()
        #expect(await task.value == false)
        #expect(store.selectedFeatureID == "another-feature")
        #expect(store.error == nil)
    }

    @Test("File cards update for edits with the same IDs and for renamed or removed documents")
    func fileCardContentIdentity() async {
        let cards = FirstMateTranscriptFileCards()
        var message = FirstMateMessage(id: "reply", featureID: "feature", role: "assistant",
            text: "Read the Plan.", status: "delivered", createdAt: "2030-01-01T00:00:00Z")
        var document = FirstMateDocument(id: "doc", featureID: "feature", title: "Plan",
            mediaType: "text/plain", contentHash: "a", createdAt: "2030-01-01T00:00:00Z")
        await cards.update(.init(messages: [message], documents: [document]))
        #expect(cards.cards == ["reply": [document]])
        message.text = "Read the Code."
        await cards.update(.init(messages: [message], documents: [document]))
        #expect(cards.cards.isEmpty)
        document.title = "Code"
        await cards.update(.init(messages: [message], documents: [document]))
        #expect(cards.cards == ["reply": [document]])
        document.content = "Revised content"
        await cards.update(.init(messages: [message], documents: [document]))
        #expect(cards.cards["reply"]?.first?.content == "Revised content")
        await cards.update(.init(messages: [message], documents: []))
        #expect(cards.cards.isEmpty)
    }

    @Test("A cancelled file-card scan cannot replace the accepted conversation")
    func cancelledFileCards() async {
        let cards = FirstMateTranscriptFileCards()
        let message = FirstMateMessage(id: "reply", featureID: "feature", role: "assistant",
            text: "Read the Plan.", status: "delivered", createdAt: "2030-01-01T00:00:00Z")
        let document = FirstMateDocument(id: "doc", featureID: "feature", title: "Plan",
            mediaType: "text/plain", contentHash: "a", createdAt: "2030-01-01T00:00:00Z")
        await cards.update(.init(messages: [message], documents: [document]))
        let cancelled = Task { await cards.update(.init(messages: [], documents: [])) }
        cancelled.cancel()
        await cancelled.value
        #expect(cards.cards == ["reply": [document]])
    }
}
