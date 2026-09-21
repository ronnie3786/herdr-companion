import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate usage contract", .serialized)
@MainActor
struct FirstMateUsageTests {
    @Test("Old payloads decode without inventing zero usage")
    func oldPayload() throws {
        let data = Data(#"{"id":"feature","title":"Timer","goal":"Plan","cwd":"/workspace","status":"ready","revision":1,"created_at":"now","updated_at":"now"}"#.utf8)
        let feature = try JSONDecoder().decode(FirstMateFeature.self, from: data)
        #expect(feature.usage == nil)
        #expect(FirstMateUsageFormatting.compactCost(feature.usage) == "Unavailable")
        #expect(FirstMateUsageFormatting.accessibilityDescription(feature.usage).contains("may need an update"))
    }

    @Test("Zero, tiny, partial, and unavailable costs remain distinct")
    func costStates() {
        #expect(FirstMateUsageFormatting.compactCost(usage(cost: 0)) == "$0.00")
        #expect(FirstMateUsageFormatting.compactCost(usage(cost: 0.004)) == "<$0.01")
        #expect(FirstMateUsageFormatting.compactCost(usage(cost: nil, status: "unavailable")) == "Unavailable")
        let partial = usage(cost: 1.25, status: "partial")
        #expect(FirstMateUsageFormatting.compactCost(partial) == "$1.25*")
        #expect(FirstMateUsageFormatting.inlineSummary(partial).contains("Partial"))
        #expect(FirstMateUsageFormatting.accessibilityDescription(partial).contains("Partial coverage"))
        #expect(FirstMateUsageFormatting.accessibilityDescription(partial).contains("not a provider invoice"))
        var stale = usage(cost: 1.25)
        stale.stale = true
        #expect(FirstMateUsageFormatting.compactCost(stale) == "$1.25*")
        #expect(FirstMateUsageFormatting.inlineSummary(stale).contains("Last reported"))
        #expect(FirstMateUsageFormatting.taskAccessibilityDescription(stale).contains("all retained managed sessions"))
    }

    @Test("Mixed historical models decode independently from the configured coordinator model")
    func mixedModels() throws {
        let data = Data(#"{"id":"feature","title":"Timer","goal":"Plan","cwd":"/workspace","status":"ready","revision":1,"created_at":"now","updated_at":"now","coordinator_model":"configured/future-model","usage":{"currency":"USD","cost_usd":1.25,"status":"complete","input_tokens":100,"output_tokens":20,"cache_read_tokens":30,"cache_write_tokens":0,"total_tokens":150,"usage_records":2,"missing_cost_records":0,"session_count":1,"known_cost_sessions":1,"models":[{"provider":"provider-a","model":"used-a","cost_usd":1.0,"status":"complete","input_tokens":80,"output_tokens":10,"cache_read_tokens":20,"cache_write_tokens":0,"total_tokens":110,"usage_records":1,"missing_cost_records":0},{"provider":null,"model":null,"cost_usd":0.25,"status":"complete","input_tokens":20,"output_tokens":10,"cache_read_tokens":10,"cache_write_tokens":0,"total_tokens":40,"usage_records":1,"missing_cost_records":0}],"updated_at":"2026-09-21T20:00:00Z"}}"#.utf8)
        let feature = try JSONDecoder().decode(FirstMateFeature.self, from: data)
        #expect(feature.modelDisplayName == "future-model")
        #expect(FirstMateUsageFormatting.modelNames(feature.usage) == "provider-a / used-a, Unknown model")
        #expect(!FirstMateUsageFormatting.modelNames(feature.usage).contains("future-model"))
    }

    @Test("Synthetic task totals include coordinator, worker, predecessor, and advisor sessions once")
    func syntheticInventoryTotal() throws {
        let snapshot = FirstMateDemo.features(step: 5)[0]
        let featureCost = try #require(snapshot.feature.usage?.costUSD)
        let sessionCost = snapshot.sessions.reduce(0) { $0 + ($1.usage?.costUSD ?? 0) }
        #expect(abs(featureCost - sessionCost) < 0.000_001)
        #expect(snapshot.coordinatorSessions.count == 2)
        #expect(snapshot.advisorSessions.count == 1)
        let successor = try #require(snapshot.assignments.first { $0.id == "demo-successor" })
        let successorSessions = snapshot.sessions(for: successor.id)
        let successorCost = try #require(successor.usage?.costUSD)
        #expect(successorSessions.count == 2)
        #expect(abs(successorCost - successorSessions.reduce(0) { $0 + ($1.usage?.costUSD ?? 0) }) < 0.000_001)
        #expect(successorCost > (successorSessions.first { $0.nativeSessionID == successor.nativeSessionID }?.usage?.costUSD ?? .infinity))
    }

    @Test("Feature totals are authoritative and never recomputed from truncated sessions")
    func aggregateIsAuthoritative() {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.usage = usage(cost: 9.99, sessions: 1_200, knownSessions: 1_199)
        snapshot.sessions = [
            session(id: "one", kind: "worker", cost: 80),
            session(id: "two", kind: "advisor", cost: 90),
        ]
        snapshot.sessionsTruncated = true
        #expect(snapshot.feature.usage?.costUSD == 9.99)
        #expect(snapshot.feature.usage?.sessionCount == 1_200)
        #expect(snapshot.sessions.map { $0.usage?.costUSD ?? 0 }.reduce(0, +) == 170)
    }

    @Test("Coordinator and advisor histories are classified without role-label inference")
    func sessionKinds() {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.sessions = [
            session(id: "coordinator", role: "first_mate", kind: "coordinator", cost: 1),
            session(id: "advisor", role: "first_mate", kind: "advisor", cost: 2),
            session(id: "legacy", role: "first_mate", kind: nil, cost: 3),
        ]
        #expect(snapshot.coordinatorSessions.map(\.nativeSessionID) == ["coordinator", "legacy"])
        #expect(snapshot.advisorSessions.map(\.nativeSessionID) == ["advisor"])
        #expect(snapshot.advisorSessions[0].kindDisplayName == "Advisor")
    }

    @Test("Refresh accepts usage growth without a workflow revision")
    func refreshUsageWithoutRevision() async {
        let base = FirstMateDemo.features(step: 0)[0]
        var listFeature = base.feature
        listFeature.usage = usage(cost: 1)
        var detail = base
        detail.feature.usage = usage(cost: 2)
        let store = FirstMateStore()
        store.configure(client: UsageClient(listFeature: listFeature, detail: detail), demo: false)
        await store.refresh()
        #expect(store.features.first?.usage?.costUSD == 2)
        #expect(store.snapshot?.feature.usage?.costUSD == 2)
    }

    @Test("Feature switching keeps each server-provided aggregate isolated")
    func featureSwitching() {
        let store = FirstMateStore()
        var first = FirstMateDemo.features(step: 0)[0]
        first.feature.usage = usage(cost: 1)
        var second = FirstMateDemo.features(step: 0)[1]
        second.feature.usage = usage(cost: 2)
        store.receive(first)
        store.receive(second)
        store.select(first.feature.id)
        #expect(store.snapshot?.feature.usage?.costUSD == 1)
        store.select(second.feature.id)
        #expect(store.snapshot?.feature.usage?.costUSD == 2)
    }

    @Test("Whole-session usage survives transcript pagination")
    func wholeSessionUsage() async throws {
        let sessionUsage = usage(cost: 0, sessions: 1, knownSessions: 1)
        let client = UsageClient(sessionUsage: sessionUsage)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let agent = FirstMateDemo.features(step: 0)[0].assignments[0]
        await store.open(.session(agent))
        #expect(store.resourceUsage == sessionUsage)
        await store.loadEarlierSessionMessages()
        #expect(store.resourceUsage == sessionUsage)
        #expect(store.sessionLoadedMessages == 2)
    }

    @Test("Missing or failed transcript usage never substitutes an assignment subtotal")
    func exactSessionFallback() async throws {
        var snapshot = FirstMateDemo.features(step: 5)[0]
        let assignmentIndex = try #require(snapshot.assignments.firstIndex { $0.id == "demo-successor" })
        let assignmentID = snapshot.assignments[assignmentIndex].id
        let currentSessionID = try #require(snapshot.assignments[assignmentIndex].nativeSessionID)
        snapshot.sessions.append(session(id: "assignment-advisor", role: "watchdog", kind: "advisor", cost: 0.004, assignmentID: assignmentID))
        let retainedSubtotal = snapshot.sessions(for: assignmentID).reduce(0) { $0 + ($1.usage?.costUSD ?? 0) }
        snapshot.assignments[assignmentIndex].usage = usage(cost: retainedSubtotal, sessions: 3, knownSessions: 3)
        snapshot.assignments[assignmentIndex].subtreeUsage = snapshot.assignments[assignmentIndex].usage
        let assignment = snapshot.assignments[assignmentIndex]
        let currentUsage = try #require(snapshot.sessions.first { $0.nativeSessionID == currentSessionID }?.usage)
        #expect(snapshot.sessions(for: assignmentID).count == 3)
        #expect((assignment.usage?.costUSD ?? 0) > (currentUsage.costUSD ?? .infinity))
        #expect(FirstMateResource.session(assignment).usage(in: snapshot) == currentUsage)

        let missingStore = FirstMateStore()
        missingStore.configure(client: UsageClient(detail: snapshot), demo: false)
        missingStore.receive(snapshot)
        missingStore.select(snapshot.feature.id)
        await missingStore.open(.session(assignment))
        #expect(missingStore.resourceError == nil)
        #expect(missingStore.resourceUsage == currentUsage)
        #expect(missingStore.resourceUsage != assignment.usage)

        let failedStore = FirstMateStore()
        failedStore.configure(client: UsageClient(detail: snapshot, sessionFails: true), demo: false)
        failedStore.receive(snapshot)
        failedStore.select(snapshot.feature.id)
        await failedStore.open(.session(assignment))
        #expect(failedStore.resourceError != nil)
        #expect(failedStore.resourceUsage == currentUsage)
        #expect(failedStore.resourceUsage != assignment.usage)
    }

    private func usage(cost: Double?, status: String = "complete", sessions: Int = 1, knownSessions: Int = 1) -> FirstMateUsage {
        FirstMateUsage(
            currency: "USD", costUSD: cost, status: status, inputTokens: 100, outputTokens: 20,
            cacheReadTokens: 30, cacheWriteTokens: 0, totalTokens: 150, usageRecords: 2,
            missingCostRecords: status == "partial" ? 1 : 0, sessionCount: sessions,
            knownCostSessions: knownSessions,
            models: [.init(provider: "synthetic", model: "sample-model", costUSD: cost, status: status,
                           inputTokens: 100, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 0,
                           totalTokens: 150, usageRecords: 2, missingCostRecords: status == "partial" ? 1 : 0)],
            updatedAt: "2026-09-21T20:00:00Z"
        )
    }

    private func session(id: String, role: String = "worker", kind: String?, cost: Double, assignmentID: String? = nil) -> FirstMateSession {
        FirstMateSession(nativeSessionID: id, featureID: "demo-session-continuity", assignmentID: assignmentID,
                         title: id, role: role, status: "retained", generation: 1,
                         createdAt: "2026-09-21T20:00:00Z", updatedAt: "2026-09-21T20:00:00Z",
                         ownershipStatus: "retained", kind: kind, usage: usage(cost: cost))
    }
}

private actor UsageClient: FirstMateClient {
    let listFeature: FirstMateFeature
    let detail: FirstMateSnapshot
    let sessionUsage: FirstMateUsage?
    let sessionFails: Bool

    init(listFeature: FirstMateFeature? = nil, detail: FirstMateSnapshot? = nil, sessionUsage: FirstMateUsage? = nil, sessionFails: Bool = false) {
        let fallback = FirstMateDemo.features(step: 0)[0]
        self.listFeature = listFeature ?? fallback.feature
        self.detail = detail ?? fallback
        self.sessionUsage = sessionUsage
        self.sessionFails = sessionFails
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: [listFeature]) }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { detail }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        if sessionFails { throw APIError.invalidResponse }
        if before == nil {
            return .init(ok: true, nativeSessionID: id, messages: [.init(role: "assistant", text: "Latest")], nextBefore: 1, totalMessages: 2, usage: sessionUsage)
        }
        return .init(ok: true, nativeSessionID: id, messages: [.init(role: "user", text: "Earlier")], totalMessages: 2)
    }
}
