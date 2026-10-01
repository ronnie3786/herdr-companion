import Foundation
import Observation
import os
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate poll presentation")
@MainActor
struct FirstMatePollPresentationTests {
    private func snapshot() -> FirstMateSnapshot {
        var snapshot = FirstMateSnapshot(feature: ChatFixtures.feature("synthetic"))
        snapshot.runtimeHealth = FirstMateRuntimeHealth(status: "healthy", schedulerAlive: true,
            lastSuccessAt: "2030-01-01T00:00:00Z", errorKind: nil, consecutiveFailures: 0)
        return snapshot
    }

    @Test("Heartbeat-only snapshots stay quiet while a changed feature publishes")
    func quietPoll() {
        let store = FirstMateStore()
        var snapshot = snapshot()
        store.receive(snapshot)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.snapshots
            _ = store.features
            _ = store.runtimeHealth
        } onChange: { changes.withLock { $0 += 1 } }
        snapshot.runtimeHealth?.lastSuccessAt = "2030-01-01T00:00:10Z"
        store.receive(snapshot)
        #expect(changes.withLock { $0 } == 0)
        snapshot.feature.status = "paused"
        store.receive(snapshot)
        #expect(changes.withLock { $0 } == 1)
        #expect(store.snapshots[snapshot.feature.id]?.feature.status == "paused")
    }

    @Test("Unchanged feature list polls do not redraw")
    func listPoll() async throws {
        let snapshot = snapshot()
        let client = SyntheticChatFleetClient(features: [snapshot.feature])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        client.snapshots = [snapshot.feature.id: snapshot]
        await store.refresh()
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = store.features; _ = store.snapshots } onChange: { changes.withLock { $0 += 1 } }
        await store.refresh()
        #expect(changes.withLock { $0 } == 0)
    }

    @Test("Warnings, transcript edits and event ordering remain observable")
    func meaningfulChanges() {
        let original = snapshot()
        var next = original
        next.runtimeHealth?.status = "stalled"
        #expect(!FirstMatePollPresentation.sameSnapshot(original, next))
        var laterWarning = next
        laterWarning.runtimeHealth?.lastSuccessAt = "2030-01-01T00:00:20Z"
        #expect(!FirstMatePollPresentation.sameSnapshot(next, laterWarning))
        next = original
        next.eventCursor = 5
        #expect(!FirstMatePollPresentation.sameSnapshot(original, next))
        next = original
        next.messages.append(.init(id: "reply", featureID: original.feature.id, role: "assistant",
            text: "An actual reply", status: "delivered", createdAt: "2030-01-01T00:00:10Z"))
        #expect(!FirstMatePollPresentation.sameSnapshot(original, next))
    }

    @Test("Conversation polls reuse capabilities and never request the list")
    func directConversation() async {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1")])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.select("f1")
        await store.refreshConversation()
        await store.refreshConversation()
        #expect(client.featureCalls == 2)
        #expect(client.featureListCalls == 0)
        #expect(client.capabilityCalls == 1)
        #expect(store.selectedFeatureID == "f1")
        #expect(store.snapshots["f1"] != nil)
    }

    @Test("A main-window conversation can open while its independent list refresh is blocked")
    func conversationDoesNotWaitForList() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1")])
        let gate = FirstMatePerformanceReadGate()
        client.beforeFeatureList = { await gate.wait() }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.select("f1")
        let list = Task { await store.refresh(includeConversation: false) }
        try await ChatFixtures.waitUntil("list is in flight") { client.featureListCalls == 1 }
        await store.refreshConversation()
        #expect(store.snapshots["f1"] != nil)
        #expect(client.featureCalls == 1)
        await gate.release()
        await list.value
        #expect(client.featureCalls == 1, "The list does not duplicate the conversation request")
    }

    @Test("A late cancelled read cannot overwrite a newer read of the same conversation")
    func cancelledRead() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1")])
        let gate = FirstMatePerformanceReadGate()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        store.select("f1")
        client.beforeFeature = { _ in await gate.wait() }
        let old = Task { await store.refreshConversation() }
        try await ChatFixtures.waitUntil("old snapshot started") { client.featureCalls == 1 }
        old.cancel()
        var newer = FirstMateSnapshot(feature: ChatFixtures.feature("f1", title: "New response"))
        newer.messages = [.init(id: "new", featureID: "f1", role: "assistant", text: "New response",
            status: "delivered", createdAt: "2030-01-01T00:00:00Z")]
        client.snapshots = ["f1": newer]
        client.beforeFeature = nil
        await store.refreshConversation()
        await gate.release()
        await old.value
        #expect(store.snapshots["f1"]?.messages.last?.text == "New response")
    }
}

actor FirstMatePerformanceReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
