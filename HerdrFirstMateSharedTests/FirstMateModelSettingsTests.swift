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
        #expect(feature.modelSelection == nil)
    }

    @Test("Actual routing metadata stays distinct from the requested policy")
    func actualSelection() throws {
        let data = Data(#"{"id":"assignment","feature_id":"feature","visit_id":"visit","title":"Implement","role":"implementation","status":"running","attempt":1,"generation":1,"input_revision":2,"updated_at":"now","model_selection":{"profile":"execution","requested_model":"synthetic/requested","requested_thinking":"low","actual_model":"synthetic/observed","actual_thinking":"high","source":"host_policy"}}"#.utf8)
        let assignment = try JSONDecoder().decode(FirstMateAssignment.self, from: data)
        let selection = try #require(assignment.modelSelection)
        #expect(selection.compactDisplayName == "observed · high")
        #expect(selection.fullDisplayName == "Actual synthetic/observed · high")
        #expect(selection.requestedThinking == "low")
    }

    @Test("Unknown actual routing is clearly labeled as requested")
    func requestedSelection() throws {
        let data = Data(#"{"native_session_id":"session","feature_id":"feature","assignment_id":"assignment","title":"Plan","role":"planner","status":"queued","generation":1,"created_at":"now","updated_at":"now","ownership_status":"queued","model_selection":{"profile":"planning","requested_model":"synthetic/planner","requested_thinking":"xhigh","actual_model":null,"actual_thinking":null,"source":"host_policy"}}"#.utf8)
        let session = try JSONDecoder().decode(FirstMateSession.self, from: data)
        #expect(session.modelSelection?.compactDisplayName == "Requested planner · xhigh")
        #expect(session.modelSelection?.fullDisplayName == "Requested synthetic/planner · xhigh")
    }

    @Test("Old and routed catalogs both decode")
    func catalogCompatibility() throws {
        let old = Data(#"{"ok":true,"models":[],"default_model":"synthetic/default","thinking_levels":["low"]}"#.utf8)
        #expect(try JSONDecoder().decode(FirstMateModelCatalog.self, from: old).routing == nil)

        let routed = Data(#"{"ok":true,"models":[],"default_model":"synthetic/default","thinking_levels":["low"],"routing":{"coordinator":{"model":"synthetic/coordinator","thinking":"low"},"planning":{"model":"synthetic/planner","thinking":"high"},"execution":{"model":"synthetic/worker","thinking":"medium"}}}"#.utf8)
        let catalog = try JSONDecoder().decode(FirstMateModelCatalog.self, from: routed)
        #expect(catalog.routing?.coordinator.compactDisplayName == "coordinator · low")
        #expect(catalog.routing?.planning.model == "synthetic/planner")
        #expect(catalog.routing?.execution.thinking == "medium")
    }

    @Test("Session responses decode optional observed routing")
    func sessionResponseSelection() throws {
        let old = Data(#"{"ok":true,"native_session_id":"session","messages":[]}"#.utf8)
        #expect(try JSONDecoder().decode(FirstMateSessionResponse.self, from: old).modelSelection == nil)

        let current = Data(#"{"ok":true,"native_session_id":"session","messages":[],"model_selection":{"profile":"coordinator","requested_model":"synthetic/coordinator","requested_thinking":"medium","actual_model":"synthetic/coordinator","actual_thinking":"low","source":"feature_override"}}"#.utf8)
        #expect(try JSONDecoder().decode(FirstMateSessionResponse.self, from: current).modelSelection?.compactDisplayName == "coordinator · low")
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
