import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent board state")
@MainActor
struct AgentBoardStateTests {
    @Test("Filters hide nonwaiting features without losing each host's draft and tab")
    func filtersAndPersistence() {
        let board = AgentBoardState()
        let waiting = entry(host: "alpha", status: "awaiting_direction")
        let working = entry(host: "beta", status: "running")
        let paused = entry(host: "gamma", status: "paused")
        let unknown = entry(host: "delta", status: "new_server_state")
        let first = board.column(for: waiting)
        first.draft = "Keep this direction"
        first.tab = .workflow
        let second = board.column(for: working)
        second.draft = "Independent host"
        second.tab = .agents
        let entries = [waiting, working, paused, unknown]
        #expect(board.entries(entries, focusMode: true).map(\.machineID) == ["alpha"])
        board.filter = .working
        #expect(board.entries(entries, focusMode: false).map(\.machineID) == ["beta"])
        #expect(board.entries(entries, focusMode: true).isEmpty)
        board.filter = .all
        #expect(board.column(for: waiting) === first)
        #expect(first.draft == "Keep this direction")
        #expect(first.tab == .workflow)
        #expect(second.draft == "Independent host")
        #expect(second.tab == .agents)
    }

    @Test("Column refresh requests one snapshot and never requests the fleet list")
    func snapshotOnlyPolling() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "One snapshot"))
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        await state.refresh()
        await state.refresh()
        #expect(await client.snapshotCalls == 2)
        #expect(await client.listCalls == 0)
        #expect(state.snapshot?.feature.title == "One snapshot")
    }

    @Test("Delayed snapshot from old credentials cannot populate a reconfigured column")
    func delayedSnapshotIsolation() async throws {
        let old = AgentBoardTestClient(snapshot: snapshot(title: "Old endpoint"), delayFetch: true)
        let new = AgentBoardTestClient(snapshot: snapshot(title: "New endpoint"))
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("old"), generation: 1, demo: false, client: old)
        let task = Task { await state.refresh() }
        try await waitUntil { await old.snapshotCalls == 1 }
        state.draft = "Never move this to the replacement host"
        state.configure(configuration: configuration("new"), generation: 2, demo: false, client: new)
        #expect(state.draft.isEmpty)
        await state.refresh()
        await old.releaseFetch()
        await task.value
        #expect(state.snapshot?.feature.title == "New endpoint")
    }

    @Test("A cancelled offscreen fetch cannot apply its delayed result")
    func cancelledSnapshot() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Cancelled"), delayFetch: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        let task = Task { await state.refresh() }
        try await waitUntil { await client.snapshotCalls == 1 }
        task.cancel()
        await client.releaseFetch()
        await task.value
        #expect(state.snapshot == nil)
        #expect(!state.isLoading)
    }

    @Test("Send uses owning host and rejects captured stale connection generations")
    func sendIsolation() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"))
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        await state.refresh()
        state.draft = "Only to Alpha"
        await state.send(configuration: configuration("beta"), generation: 4, canControl: true, isCurrent: { true })
        await state.send(configuration: config, generation: 3, canControl: true, isCurrent: { true })
        await state.send(configuration: config, generation: 4, canControl: false, isCurrent: { true })
        await state.send(configuration: config, generation: 4, canControl: true, isCurrent: { false })
        #expect(await client.sentMessages.isEmpty)
        #expect(state.draft == "Only to Alpha")
        await state.send(configuration: config, generation: 4, canControl: true, isCurrent: { true })
        #expect(await client.sentMessages == ["Only to Alpha"])
        #expect(state.draft.isEmpty)
        #expect(await client.listCalls == 0)
    }

    @Test("Retry retains the same request identity and text after an uncertain send")
    func sendRetry() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), failFirstSend: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        await state.refresh()
        state.draft = "Retry safely"
        await state.send(configuration: config, generation: 4, canControl: true, isCurrent: { true })
        #expect(state.draft == "Retry safely")
        #expect(state.sendError != nil)
        await state.send(configuration: config, generation: 4, canControl: true, isCurrent: { true })
        let requests = await client.requestIDs
        #expect(requests.count == 2)
        #expect(Set(requests).count == 1)
        #expect(state.draft.isEmpty)
    }

    @Test("Leaving or replacing a request cannot erase text typed during its send")
    func preservesNewDraftDuringSend() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), delaySend: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        await state.refresh()
        state.draft = "First direction"
        let task = Task { await state.send(configuration: config, generation: 4, canControl: true, isCurrent: { true }) }
        try await waitUntil { await client.sentMessages.count == 1 }
        state.draft = "Next direction"
        await client.releaseSend()
        await task.value
        #expect(state.draft == "Next direction")
    }

    @Test("Demo columns use the shell's actual feature snapshots")
    func seedDemoSnapshot() {
        let state = AgentBoardColumnState(machineID: "demo", featureID: "shared")
        let seed = snapshot(title: "Current demo feature")
        state.configure(configuration: nil, generation: 0, demo: true, client: nil, demoSnapshot: seed)
        #expect(state.snapshot?.feature.title == "Current demo feature")
        state.draft = "Retain demo direction"
        state.tab = .agents
        var updated = seed
        updated.feature.revision += 1
        updated.feature.title = "Changed scenario"
        state.receiveDemoSnapshot(updated)
        #expect(state.snapshot?.feature.title == "Changed scenario")
        #expect(state.draft == "Retain demo direction")
        #expect(state.tab == .agents)
    }

    @Test("Live agent navigation never picks a same-named session on another host")
    func liveSessionHostIsolation() throws {
        let data = Data("""
        {"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,
         "agent_status":"working","revision":1,"pi_semantic":{"available":true,"connected":true,
         "protocolVersion":1,"sessionId":"same-session"}}
        """.utf8)
        let pane = try JSONDecoder().decode(HerdrPane.self, from: data)
        let alpha = pane.stamped(machineID: "alpha")
        let beta = pane.stamped(machineID: "beta")
        #expect(AgentBoardSessionRoute.livePane(nativeSessionID: "same-session", machineID: "beta", panes: [alpha, beta])?.machineID == "beta")
        #expect(AgentBoardSessionRoute.livePane(nativeSessionID: "same-session", machineID: "gamma", panes: [alpha, beta]) == nil)
        #expect(AgentBoardSessionRoute.livePane(nativeSessionID: "", machineID: "alpha", panes: [alpha]) == nil)
    }

    private func entry(host: String, status: String) -> DashboardFeatureEntry {
        var value = snapshot(title: host).feature
        value.status = status
        return .init(machineID: host, machineName: host, feature: value)
    }

    private func configuration(_ name: String) -> ServerConfiguration {
        ServerConfiguration(urlString: "https://\(name).example.invalid", token: "synthetic-token")!
    }

    private func snapshot(title: String) -> FirstMateSnapshot {
        .init(feature: .init(id: "shared", title: title, goal: "Synthetic goal", cwd: "/tmp/synthetic", status: "awaiting_direction",
                             revision: 1, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for synthetic request")
        throw CancellationError()
    }
}

private actor AgentBoardTestClient: FirstMateClient {
    let snapshot: FirstMateSnapshot
    let delayFetch: Bool
    let delaySend: Bool
    let failFirstSend: Bool
    private(set) var snapshotCalls = 0
    private(set) var listCalls = 0
    private(set) var sentMessages: [String] = []
    private(set) var requestIDs: [String] = []
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: FirstMateSnapshot, delayFetch: Bool = false, delaySend: Bool = false, failFirstSend: Bool = false) {
        self.snapshot = snapshot
        self.delayFetch = delayFetch
        self.delaySend = delaySend
        self.failFirstSend = failFirstSend
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        snapshotCalls += 1
        if delayFetch { await withCheckedContinuation { fetchContinuation = $0 } }
        return snapshot
    }
    func releaseFetch() { fetchContinuation?.resume(); fetchContinuation = nil }
    func releaseSend() { sendContinuation?.resume(); sendContinuation = nil }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        listCalls += 1
        return .init(ok: true, features: [snapshot.feature])
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        sentMessages.append(text)
        requestIDs.append(requestID)
        if failFirstSend, requestIDs.count == 1 { throw APIError.invalidResponse }
        if delaySend { await withCheckedContinuation { sendContinuation = $0 } }
        return snapshot
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
