import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate nonselecting creation receipts", .serialized)
@MainActor
struct FirstMateCreationReceiptTests {
    @Test("Receipt caching preserves a newer selection and its draft while preserving busy semantics")
    func cacheWithoutSelection() async throws {
        let store = FirstMateStore(), gate = ChatTestGate()
        store.configure(client: nil, demo: true)
        let original = store.operationContext
        let other = try #require(store.features.first { !original.matchesFeature($0.id) })
        let created = FirstMateDemo.newFeature(title: "Created", goal: "Synthetic", cwd: "/workspace/synthetic", id: "created")
        let operation = Task { await store.receiveCreation(expectedContext: original) { await gate.wait(); return created } }
        defer { Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isSending)
        store.select(other.id); store.draft = "Newer draft"
        let current = store.operationContext
        await gate.open()
        #expect(await operation.value?.feature.id == "created")
        #expect(store.operationContext == current && store.draft == "Newer draft")
        #expect(store.snapshots["created"] != nil && !store.isSending)
    }

    @Test("Retirement rejects delayed receipts and stale contexts without executing transport")
    func retirement() async throws {
        let store = FirstMateStore(), gate = ChatTestGate()
        store.configure(client: nil, demo: true)
        let original = store.operationContext
        let created = FirstMateDemo.newFeature(title: "Created", goal: "Synthetic", cwd: "/workspace/synthetic", id: "created")
        let operation = Task { await store.receiveCreation(expectedContext: original) { await gate.wait(); return created } }
        defer { Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        store.configure(client: nil, demo: true)
        await gate.open()
        #expect(await operation.value == nil)
        #expect(store.snapshots["created"] == nil && !store.isSending)
        var called = false
        _ = await store.receiveCreation(expectedContext: original) { called = true; return created }
        #expect(!called)
    }

    @Test("Current-owner errors remain visible and release the transport busy state")
    func failure() async {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let context = store.operationContext
        let result = await store.receiveCreation(expectedContext: context) {
            throw APIError.server(status: 409, message: "Synthetic creation conflict")
        }
        #expect(result == nil && store.error == "Synthetic creation conflict")
        #expect(store.operationContext == context && !store.isSending)
    }
}
