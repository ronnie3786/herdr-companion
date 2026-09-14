import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate model settings") @MainActor
struct FirstMateModelSettingsTests {
    @Test("Older server features decode without pretending model controls exist")
    func oldServer() throws {
        let data = Data(#"{"id":"feature","title":"Timer","goal":"Plan","cwd":"/workspace","status":"ready","revision":1,"created_at":"now","updated_at":"now"}"#.utf8)
        let feature = try JSONDecoder().decode(FirstMateFeature.self, from: data)
        #expect(feature.modelSettingsRevision == nil)
        #expect(feature.modelDisplayName == "Host default")
    }

    @Test("Stale polls cannot roll back saved model settings")
    func stalePoll() {
        let store = FirstMateStore()
        var snapshot = FirstMateDemo.features(step: 0)[0]
        let old = snapshot
        snapshot.feature.coordinatorModel = "synthetic/reasoner"
        snapshot.feature.modelSettingsRevision = 2
        store.receive(snapshot)
        store.receive(old)
        #expect(store.snapshots[snapshot.feature.id]?.feature.coordinatorModel == "synthetic/reasoner")
    }

    @Test("A pending settings update cannot land on another host")
    func switchedHost() async throws {
        let store = FirstMateStore()
        let client = ModelSettingsClient()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        let settings = FirstMateModelSettings(model: "synthetic/reasoner", thinking: "high", expectedSettingsRevision: 0, requestID: "request")
        let task = Task { try await store.saveModelSettings(settings, expectedContext: context) }
        while !(await client.isWaiting) { await Task.yield() }
        store.configure(client: nil, demo: false)
        await client.release()
        await #expect(throws: APIError.self) { try await task.value }
        #expect(store.features.isEmpty)
        #expect(!store.isSending)
    }
}

private actor ModelSettingsClient: FirstMateClient {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: [FirstMateDemo.features(step: 0)[0].feature]) }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { FirstMateDemo.features(step: 0)[0] }
    func setFirstMateModel(featureID: String, settings: FirstMateModelSettings) async throws -> FirstMateSnapshot {
        await withCheckedContinuation { continuation = $0 }
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.coordinatorModel = settings.model
        snapshot.feature.modelSettingsRevision = 1
        return snapshot
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
