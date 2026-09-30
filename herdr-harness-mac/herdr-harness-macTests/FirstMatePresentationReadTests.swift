import Foundation
import Observation
import os
import Testing
@testable import herdr_harness_mac

@Suite("First Mate independent presentation reads", .timeLimit(.minutes(1)))
@MainActor
struct FirstMatePresentationReadTests {
    private func setup() -> (FirstMateStore, SyntheticChatFleetClient) {
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-read-views-v1"]), features: [ChatFixtures.feature("f1")])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.select("f1")
        return (store, client)
    }

    private nonisolated static func page(_ ids: [String], version: String = "v1", before: String? = nil) -> FirstMatePresentationResponse {
        var snapshot = FirstMateSnapshot(feature: ChatFixtures.feature("f1"))
        snapshot.messages = ids.map {
            FirstMateMessage(id: $0, featureID: "f1", role: "assistant", text: "Reply \($0)", status: "delivered", createdAt: "2030-01-01T00:00:\($0)Z")
        }
        var response = FirstMatePresentationResponse(snapshot: snapshot)
        response.version = version
        response.nextBefore = before
        return response
    }

    @Test("An unchanged chat response does not publish or decode a snapshot")
    func unchanged() async throws {
        let (store, client) = setup()
        client.presentation = { _, _, _, version in
            if let version {
                return try JSONDecoder().decode(FirstMatePresentationResponse.self, from: Data("{\"ok\":true,\"unchanged\":true,\"version\":\"\(version)\"}".utf8))
            }
            return Self.page(["02"], before: "02")
        }
        await store.refreshConversation()
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = store.snapshots } onChange: { changes.withLock { $0 += 1 } }
        await store.refreshConversation()
        #expect(changes.withLock { $0 } == 0)
        #expect(store.snapshot?.messages.map(\.id) == ["02"])
        #expect(store.earlierMessageCursors["f1"] == "02")
    }

    @Test("Overview can finish while chat is blocked and never replaces its transcript")
    func independentOverview() async throws {
        let (store, client) = setup()
        let gate = ChatTestGate()
        client.presentation = { _, view, _, _ in
            if view == .chat { await gate.wait(); return Self.page(["02"]) }
            return Self.page([], version: "overview")
        }
        let chat = Task { await store.refreshConversation() }
        while !(await gate.arrived) { await Task.yield() }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview) != nil)
        #expect(store.snapshot == nil)
        await gate.open()
        await chat.value
        #expect(store.snapshot?.messages.map(\.id) == ["02"])
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.snapshot?.messages.map(\.id) == ["02"])
    }

    @Test("Earlier pages merge once and survive an overlapping tail refresh")
    func pagination() async {
        let (store, client) = setup()
        client.presentation = { _, _, before, _ in
            before == nil ? Self.page(["02", "03"], before: "02") : Self.page(["01", "02"], version: "older")
        }
        await store.refreshConversation()
        await store.loadEarlierMessages()
        #expect(store.snapshot?.messages.map(\.id) == ["01", "02", "03"])
        #expect(store.earlierMessageCursors["f1"] == nil)
        client.presentation = { _, _, _, _ in Self.page(["03", "04"], version: "v2", before: "03") }
        await store.refreshConversation()
        #expect(store.snapshot?.messages.map(\.id) == ["01", "02", "03", "04"])
        #expect(store.earlierMessageCursors["f1"] == nil)
    }

    @Test("A disconnected tail resets pagination instead of hiding a gap")
    func gap() async {
        let (store, client) = setup()
        client.presentation = { _, _, _, _ in Self.page(["01", "02"], before: "01") }
        await store.refreshConversation()
        client.presentation = { _, _, _, _ in Self.page(["40", "41"], version: "v2", before: "40") }
        await store.refreshConversation()
        #expect(store.snapshot?.messages.map(\.id) == ["40", "41"])
        #expect(store.earlierMessageCursors["f1"] == "40")
    }

    @Test("A mutation fences an already in-flight conditional read")
    func mutationFencesRead() async throws {
        let (store, client) = setup()
        let gate = ChatTestGate()
        client.presentation = { _, _, _, _ in await gate.wait(); return Self.page(["01"]) }
        let poll = Task { await store.refreshConversation() }
        while !(await gate.arrived) { await Task.yield() }
        store.receive(try #require(Self.page(["02"]).snapshot))
        await gate.open()
        await poll.value
        #expect(store.snapshot?.messages.map(\.id) == ["02"])
    }

    @Test("A stale model-settings response cannot install its conditional version")
    func modelRevisionFence() async throws {
        let (store, client) = setup()
        var newest = try #require(Self.page(["02"]).snapshot)
        newest.feature.modelSettingsRevision = 3
        store.receive(newest)
        let versions = OSAllocatedUnfairLock(initialState: [String?]())
        client.presentation = { _, _, _, version in
            versions.withLock { $0.append(version) }
            var response = Self.page(["01"])
            response.snapshot?.feature.modelSettingsRevision = 2
            return response
        }
        await store.refreshConversation()
        await store.refreshConversation()
        #expect(store.snapshot?.feature.modelSettingsRevision == 3)
        #expect(versions.withLock { $0.count == 2 && $0.allSatisfy { $0 == nil } })
    }

    @Test("Queued work outside the chat page is retained in the compact contract")
    func queuedWork() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.page([]).snapshot!)) as! [String: Any]
        object["has_queued_work"] = true
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.hasQueuedWork == true)
    }
}
