import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate inspector activity freshness", .timeLimit(.minutes(1)))
@MainActor
struct FirstMateInspectorFreshnessTests {
    private func setup() -> (FirstMateStore, SyntheticChatFleetClient) {
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-read-views-v1"]), features: [ChatFixtures.feature("f1")])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.select("f1")
        return (store, client)
    }

    private nonisolated static func page(_ text: String, cursor: Int = 1, modelRevision: Int = 0) -> FirstMatePresentationResponse {
        var snapshot = FirstMateSnapshot(feature: ChatFixtures.feature("f1"))
        snapshot.feature.modelSettingsRevision = modelRevision
        snapshot.eventCursor = cursor
        snapshot.pendingMessages = [.init(id: "direction", featureID: "f1", role: "user", text: text, status: "queued", createdAt: "2030-01-01T00:00:00Z")]
        var response = FirstMatePresentationResponse(snapshot: snapshot)
        response.version = "v\(cursor)-\(text)"
        return response
    }

    @Test("Mutation receipts fence an inspector request already in flight")
    func mutationFence() async throws {
        let (store, client) = setup()
        client.presentation = { _, _, _, _ in Self.page("Previous direction") }
        await store.refreshInspector(featureID: "f1", view: .overview)
        let key = store.inspectorKey(featureID: "f1", view: .overview)
        #expect(store.inspectorCheckedAt[key] != nil)
        let gate = ChatTestGate()
        client.presentation = { _, _, _, _ in await gate.wait(); return Self.page("Stale in-flight direction") }
        let poll = Task { await store.refreshInspector(featureID: "f1", view: .overview) }
        while !(await gate.arrived) { await Task.yield() }
        store.receive(try #require(Self.page("New direction", cursor: 2).snapshot))
        await gate.open()
        await poll.value
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview)?.pendingMessages?.first?.text == "Previous direction")
        #expect(store.inspectorCheckedAt[key] == nil)
        client.presentation = { _, _, _, version in
            #expect(version == nil)
            return Self.page("New direction", cursor: 2)
        }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview)?.pendingMessages?.first?.text == "New direction")
        #expect(store.inspectorCheckedAt[key] != nil)
    }

    @Test("Inspector cannot publish an older model or activity than the accepted conversation")
    func olderInspector() async throws {
        let (store, client) = setup()
        store.receive(try #require(Self.page("Accepted", cursor: 3, modelRevision: 2).snapshot))
        client.presentation = { _, _, _, _ in Self.page("Older", cursor: 3, modelRevision: 1) }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview) == nil)
        #expect(store.inspectorErrors[store.inspectorKey(featureID: "f1", view: .overview)] != nil)
    }

    @Test("New conversation work wakes the inspector once, while telemetry does not")
    func activityInvalidation() async throws {
        let (store, client) = setup()
        client.presentation = { _, _, _, _ in Self.page("Before") }
        await store.refreshInspector(featureID: "f1", view: .overview)
        let revision = store.inspectorRefreshRevision
        var updated = try #require(Self.page("New direction", cursor: 2).snapshot)
        store.receive(updated, isPresentationRead: true)
        #expect(store.inspectorRefreshRevision == revision + 1)
        updated.eventCursor = 100
        updated.feature.updatedAt = "2030-01-01T12:00:00Z"
        store.receive(updated, isPresentationRead: true)
        #expect(store.inspectorRefreshRevision == revision + 1)
    }

    @Test("Failed reads retain data and its checked time until a successful read confirms it")
    func failureAndRecovery() async throws {
        let (store, client) = setup()
        client.presentation = { _, _, _, _ in Self.page("Current direction") }
        await store.refreshInspector(featureID: "f1", view: .overview)
        let key = store.inspectorKey(featureID: "f1", view: .overview)
        let checkedAt = try #require(store.inspectorCheckedAt[key])
        client.presentation = { _, _, _, _ in throw URLError(.timedOut) }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorCheckedAt[key] == checkedAt)
        #expect(store.inspectorErrors[key] != nil)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview)?.pendingMessages?.first?.text == "Current direction")
        client.presentation = { _, _, _, version in
            let version = try #require(version)
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "unchanged": true, "version": version])
            return try JSONDecoder().decode(FirstMatePresentationResponse.self, from: data)
        }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorErrors[key] == nil)
        #expect(try #require(store.inspectorCheckedAt[key]) >= checkedAt)
    }
    @Test("A slower inspector remains valid when only chat telemetry has advanced")
    func newerTelemetryDoesNotStarveInspector() async throws {
        let (store, client) = setup()
        let known = try #require(Self.page("Same work", cursor: 100).snapshot)
        store.receive(known, isPresentationRead: true)
        client.presentation = { _, _, _, _ in Self.page("Same work", cursor: 10) }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview)?.eventCursor == 10)
        #expect(store.inspectorErrors[store.inspectorKey(featureID: "f1", view: .overview)] == nil)
    }

    @Test("Older queued activity cannot replace the newer work confirmed by chat")
    func olderQueueRejected() async throws {
        let (store, client) = setup()
        store.receive(try #require(Self.page("New direction", cursor: 100).snapshot), isPresentationRead: true)
        client.presentation = { _, _, _, _ in Self.page("Old direction", cursor: 10) }
        await store.refreshInspector(featureID: "f1", view: .overview)
        #expect(store.inspectorSnapshot(featureID: "f1", view: .overview) == nil)
        #expect(store.inspectorErrors[store.inspectorKey(featureID: "f1", view: .overview)] != nil)
    }

}
