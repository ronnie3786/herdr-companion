import Foundation
import Observation
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
        board.filter = .needsYou
        #expect(board.entries(entries, focusMode: false).map(\.machineID) == ["alpha"])
        board.filter = .working
        #expect(board.entries(entries, focusMode: false).map(\.machineID) == ["beta"])
        board.filter = .all
        #expect(board.entries(entries, focusMode: false).count == 4)
        #expect(board.column(for: waiting) === first)
        #expect(first.draft == "Keep this direction")
        #expect(first.tab == .workflow)
        #expect(second.draft == "Independent host")
        #expect(second.tab == .agents)
    }

    @Test("Column order stays put across polls until the view resets it")
    func stableOrder() {
        let board = AgentBoardState()
        let a = entry(host: "alpha", status: "awaiting_direction")
        let b = entry(host: "beta", status: "running")
        let c = entry(host: "gamma", status: "running")
        #expect(board.entries([a, b], focusMode: false).map(\.machineID) == ["alpha", "beta"])
        // A reply moves alpha below beta in priority order; the board holds still
        // and appends a newcomer at the end.
        #expect(board.entries([b, c, a], focusMode: false).map(\.machineID) == ["alpha", "beta", "gamma"])
        #expect(board.entries([c, a], focusMode: false).map(\.machineID) == ["alpha", "gamma"])
        board.resetOrder()
        #expect(board.entries([b, c, a], focusMode: false).map(\.machineID) == ["beta", "gamma", "alpha"])
    }

    @Test("Pruning drops departed columns but keeps unsent replies")
    func pruning() {
        let board = AgentBoardState()
        let kept = entry(host: "alpha", status: "running")
        let drafted = entry(host: "beta", status: "running")
        let gone = entry(host: "gamma", status: "running")
        let keptColumn = board.column(for: kept)
        board.column(for: drafted).draft = "Still typing"
        _ = board.column(for: gone)
        board.prune(keeping: [kept.id])
        #expect(board.existingColumn(id: kept.id) === keptColumn)
        #expect(board.existingColumn(id: drafted.id)?.draft == "Still typing")
        #expect(board.existingColumn(id: gone.id) == nil)
    }

    @Test("Capabilities are fetched once per host and shared by its columns")
    func capabilityCache() async {
        let board = AgentBoardState()
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let config = configuration("alpha")
        async let first = board.capabilities(machineID: "alpha", configuration: config, generation: 1, client: client)
        async let second = board.capabilities(machineID: "alpha", configuration: config, generation: 1, client: client)
        let values = await [first, second]
        #expect(values.allSatisfy { $0?.supportsBoard == true })
        #expect(await client.capabilityCalls == 1)
        _ = await board.capabilities(machineID: "alpha", configuration: config, generation: 2, client: client)
        #expect(await client.capabilityCalls == 2)
    }

    @Test("Board polling sends the last version and an unchanged answer publishes nothing")
    func unchangedBoardPublishesNothing() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        await state.refresh(capabilities: boardCapabilities)
        #expect(state.content?.title == "Alpha")
        let firstChange = try #require(state.lastChanged)

        let published = PublishFlag()
        withObservationTracking {
            _ = state.content
            _ = state.lastChanged
            _ = state.loadError
        } onChange: { published.set() }
        await state.refresh(capabilities: boardCapabilities)
        await state.refresh(capabilities: boardCapabilities)
        #expect(!published.value)
        #expect(state.lastChanged == firstChange)
        #expect(await client.boardVersionsSent == [nil, "v1", "v1"])
        #expect(await client.snapshotCalls == 0)

        await client.setTitle("Alpha renamed")
        await state.refresh(capabilities: boardCapabilities)
        #expect(published.value)
        #expect(state.content?.title == "Alpha renamed")
    }

    @Test("Older companions fall back to a journal-only snapshot without telemetry")
    func fallbackSnapshot() async throws {
        var value = snapshot(title: "Legacy")
        value.events = (1...500).map { index in
            event(index, type: index.isMultiple(of: 50) ? "visit.completed" : "pi.tool_execution_end", summary: "Step \(index)")
        }
        value.messages = (1...80).map { index in
            .init(id: "m\(index)", featureID: "shared", role: index.isMultiple(of: 2) ? "assistant" : "user",
                  text: "Message \(index)", status: "done", createdAt: timestamp(index))
        }
        let client = AgentBoardTestClient(snapshot: value, board: false)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        await state.refresh(capabilities: .init(ok: true, capabilities: ["first-mate-journal-events-v1"]))
        #expect(await client.journalOnlyRequests == [true])
        let content = try #require(state.content)
        #expect(content.earlierMessageCount == 20)
        #expect(content.latestNotes.map(\.text) == ["Step 500", "Step 450", "Step 400"])
        #expect(content.timeline.count == AgentBoardPayload.messageLimit)
    }

    @Test("A reply sent during a running poll is fetched as soon as that poll ends")
    func sendDuringPoll() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true, delayFetch: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        let poll = Task { await state.refresh(capabilities: boardCapabilities) }
        try await waitUntil { await client.boardVersionsSent.count == 1 }
        // A forced refresh (as after a send) arrives while the poll is running.
        await state.refresh(capabilities: boardCapabilities, force: true)
        await client.setTitle("After the reply")
        await client.releaseFetch()
        try await waitUntil { await client.boardVersionsSent.count == 2 }
        await client.releaseFetch()
        await poll.value
        #expect(await client.boardVersionsSent == [nil, nil])
        #expect(state.content?.title == "After the reply")
    }

    @Test("Unknown capabilities never fall back to the full history download")
    func unknownCapabilities() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        await state.refresh(capabilities: nil)
        #expect(await client.snapshotCalls == 0)
        #expect(await client.boardVersionsSent.isEmpty)
        #expect(state.loadError != nil)
    }

    @Test("A failed capability check keeps the last answer for the host")
    func capabilityStaleWhileError() async {
        let board = AgentBoardState()
        board.capabilityLifetime = 0
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let config = configuration("alpha")
        let first = await board.capabilities(machineID: "alpha", configuration: config, generation: 1, client: client)
        #expect(first?.supportsBoard == true)
        await client.setFailing(true)
        let second = await board.capabilities(machineID: "alpha", configuration: config, generation: 1, client: client)
        #expect(second?.supportsBoard == true)
    }

    @Test("A failed poll keeps what is on screen and recovers")
    func failureKeepsContent() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        await state.refresh(capabilities: boardCapabilities)
        await client.setFailing(true)
        await state.refresh(capabilities: boardCapabilities)
        #expect(state.content?.title == "Alpha")
        #expect(state.loadError != nil)
        await client.setFailing(false)
        await state.refresh(capabilities: boardCapabilities)
        #expect(state.loadError == nil)
    }

    @Test("Delayed board from old credentials cannot populate a reconfigured column")
    func delayedBoardIsolation() async throws {
        let old = AgentBoardTestClient(snapshot: snapshot(title: "Old endpoint"), board: true, delayFetch: true)
        let new = AgentBoardTestClient(snapshot: snapshot(title: "New endpoint"), board: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("old"), generation: 1, demo: false, client: old)
        let task = Task { await state.refresh(capabilities: boardCapabilities) }
        try await waitUntil { await old.boardVersionsSent.count == 1 }
        state.draft = "Never move this to the replacement host"
        state.configure(configuration: configuration("new"), generation: 2, demo: false, client: new)
        #expect(state.draft.isEmpty)
        await state.refresh(capabilities: boardCapabilities)
        await old.releaseFetch()
        await task.value
        #expect(state.content?.title == "New endpoint")
    }

    @Test("A cancelled offscreen fetch cannot apply its delayed result")
    func cancelledFetch() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Cancelled"), board: true, delayFetch: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        state.configure(configuration: configuration("alpha"), generation: 1, demo: false, client: client)
        let task = Task { await state.refresh(capabilities: boardCapabilities) }
        try await waitUntil { await client.boardVersionsSent.count == 1 }
        task.cancel()
        await client.releaseFetch()
        await task.value
        #expect(state.content == nil)
    }

    @Test("Send uses the owning host and rejects captured stale connection generations")
    func sendIsolation() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        state.draft = "Only to Alpha"
        await state.send(configuration: configuration("beta"), generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        await state.send(configuration: config, generation: 3, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        await state.send(configuration: config, generation: 4, canControl: false, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: false, capabilities: boardCapabilities, isCurrent: { true })
        await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { false })
        #expect(await client.sentMessages.isEmpty)
        #expect(state.draft == "Only to Alpha")
        // A reply does not wait for the column's first load.
        #expect(state.content == nil)
        await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        #expect(await client.sentMessages == ["Only to Alpha"])
        #expect(state.draft.isEmpty)
        // The conversation refreshes immediately, ignoring any cached version.
        #expect(await client.boardVersionsSent == [nil])
        #expect(state.content?.title == "Alpha")
    }

    @Test("Retry retains the same request identity and text after an uncertain send")
    func sendRetry() async {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true, failFirstSend: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        state.draft = "Retry safely"
        await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        #expect(state.draft == "Retry safely")
        #expect(state.sendError != nil)
        await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true })
        let requests = await client.requestIDs
        #expect(requests.count == 2)
        #expect(Set(requests).count == 1)
        #expect(state.draft.isEmpty)
    }

    @Test("Leaving or replacing a request cannot erase text typed during its send")
    func preservesNewDraftDuringSend() async throws {
        let client = AgentBoardTestClient(snapshot: snapshot(title: "Alpha"), board: true, delaySend: true)
        let state = AgentBoardColumnState(machineID: "alpha", featureID: "shared")
        let config = configuration("alpha")
        state.configure(configuration: config, generation: 4, demo: false, client: client)
        state.draft = "First direction"
        let task = Task { await state.send(configuration: config, generation: 4, canControl: true, acceptsMessages: true, capabilities: boardCapabilities, isCurrent: { true }) }
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
        #expect(state.content?.title == "Current demo feature")
        state.draft = "Retain demo direction"
        state.tab = .agents
        var updated = seed
        updated.feature.revision += 1
        updated.feature.title = "Changed scenario"
        state.receiveDemoSnapshot(updated)
        #expect(state.content?.title == "Changed scenario")
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

    @Test("The board envelope decodes unchanged and full responses")
    func boardResponseDecoding() throws {
        let unchanged = try JSONDecoder().decode(AgentBoardResponse.self, from: Data(#"{"ok":true,"version":"b1-x","unchanged":true}"#.utf8))
        #expect(unchanged.board == nil)
        #expect(unchanged.version == "b1-x")
        let full = try JSONDecoder().decode(AgentBoardResponse.self, from: Data("""
        {"ok":true,"version":"b1-y","unchanged":false,
         "feature":{"id":"shared","title":"Synthetic","goal":"Goal","cwd":"/tmp/synthetic","status":"running","revision":3,
                    "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
         "visits":[],"assignments":[],"messages":[],"messages_total":12,"journal":[],"journal_total":4,
         "sessions":[],"sessions_truncated":false,"event_cursor":900}
        """.utf8))
        let board = try #require(full.board)
        #expect(board.version == "b1-y")
        #expect(board.messagesTotal == 12)
        #expect(board.feature.revision == 3)
    }

    // MARK: - Fixtures

    private var boardCapabilities: FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-board-v1", "first-mate-journal-events-v1"])
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

    private func timestamp(_ minute: Int) -> String {
        HerdrTimestamp.string(from: Date(timeIntervalSince1970: 1_780_000_000 + Double(minute) * 60))
    }

    private func event(_ sequence: Int, type: String, summary: String) -> FirstMateEvent {
        .init(sequence: sequence, id: "e\(sequence)", featureID: "shared", type: type, summary: summary, createdAt: timestamp(sequence))
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

/// Observation's change callback is not main-actor isolated.
private final class PublishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private actor AgentBoardTestClient: AgentBoardClient {
    private var snapshot: FirstMateSnapshot
    let board: Bool
    let delayFetch: Bool
    let delaySend: Bool
    let failFirstSend: Bool
    private var failing = false
    private(set) var snapshotCalls = 0
    private(set) var capabilityCalls = 0
    private(set) var boardVersionsSent: [String?] = []
    private(set) var journalOnlyRequests: [Bool] = []
    private(set) var sentMessages: [String] = []
    private(set) var requestIDs: [String] = []
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: FirstMateSnapshot, board: Bool, delayFetch: Bool = false, delaySend: Bool = false, failFirstSend: Bool = false) {
        self.snapshot = snapshot
        self.board = board
        self.delayFetch = delayFetch
        self.delaySend = delaySend
        self.failFirstSend = failFirstSend
    }

    func setTitle(_ title: String) {
        snapshot.feature.title = title
        snapshot.feature.revision += 1
    }
    func setFailing(_ value: Bool) { failing = value }
    func releaseFetch() { fetchContinuation?.resume(); fetchContinuation = nil }
    func releaseSend() { sendContinuation?.resume(); sendContinuation = nil }

    private var version: String { "v\(snapshot.feature.revision)" }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        capabilityCalls += 1
        if failing { throw APIError.invalidResponse }
        return .init(ok: true, capabilities: board ? ["first-mate-board-v1"] : [])
    }

    func fetchFirstMateBoard(featureID: String, messageLimit: Int, journalLimit: Int, ifVersion: String?) async throws -> AgentBoardFetch {
        boardVersionsSent.append(ifVersion)
        if delayFetch { await withCheckedContinuation { fetchContinuation = $0 } }
        // Each held request takes its own release.
        if failing { throw APIError.invalidResponse }
        if ifVersion == version { return .unchanged(version: version) }
        var payload = AgentBoardPayload.adapting(snapshot, messageLimit: messageLimit, journalLimit: journalLimit)
        payload.version = version
        return .board(payload)
    }

    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot {
        snapshotCalls += 1
        journalOnlyRequests.append(journalEventsOnly)
        if delayFetch { await withCheckedContinuation { fetchContinuation = $0 } }
        if failing { throw APIError.invalidResponse }
        return snapshot
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        sentMessages.append(text)
        requestIDs.append(requestID)
        if failFirstSend, requestIDs.count == 1 { throw APIError.invalidResponse }
        if delaySend { await withCheckedContinuation { sendContinuation = $0 } }
        return snapshot
    }
}
