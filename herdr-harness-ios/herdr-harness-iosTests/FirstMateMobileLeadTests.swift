import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Real phone lead ownership and context", .serialized)
@MainActor
struct FirstMateMobileLeadTests {
    private func fleet() -> FirstMateMobileFleetStore {
        .init(defaults: UserDefaults(suiteName: "MobileLead.\(UUID())")!)
    }
    private func source(_ id: String, _ client: any FirstMateClient, url: String? = nil, token: String = "synthetic") -> FirstMateMobileFleetSource {
        var machine = ChatFixtures.machine(id)
        if let url { machine.urlString = url }
        return .init(machine: machine, configuration: .init(urlString: machine.urlString, token: token), client: client)
    }
    private func client(existing: Bool = true) -> SyntheticChatFleetClient {
        let value = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1"]))
        let snapshot = FirstMateDemo.chatWindowLead()
        value.snapshots = [snapshot.feature.id: snapshot]
        if existing { value.lead = summary(snapshot) }
        return value
    }
    private func summary(_ snapshot: FirstMateSnapshot) -> FirstMateLeadSummary {
        .init(feature: snapshot.feature, unread: true, workingOnReply: false,
            latestMessage: snapshot.messages.last.map { .init(id: $0.id, role: $0.role, text: $0.text, createdAt: $0.createdAt) },
            machine: .init(id: "untrusted-metadata", name: "Not an owner"))
    }
    @Test("Capable nil lead is ensured once with actual control; read-only and unsupported never POST")
    func ensureOnce() async throws {
        let fleet = fleet(), client = client(existing: false)
        let lead = summary(FirstMateDemo.chatWindowLead())
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshAll()
        client.lead = lead // The next POST creates this; the polled index still has nil.
        #expect(fleet.leadChoice.current == "alpha")
        #expect(await fleet.chat.openLead(fleet: fleet) == nil)
        #expect(fleet.chat.leadOpenError?.contains("read-only") == true)
        #expect(client.ensureCalls == 0)
        let target = try #require(await fleet.chat.openLead(fleet: fleet, canControl: { $0 == "alpha" }))
        #expect(target.machineID == "alpha" && target.featureID == lead.feature.id)
        #expect(client.ensureCalls == 1)
        for _ in 0..<3 { await fleet.refreshChatIndex(); _ = await fleet.chat.openLead(fleet: fleet) }
        #expect(client.ensureCalls == 1 && client.sent.isEmpty)
        let older = SyntheticChatFleetClient()
        fleet.activate(sources: [source("older", older)], connectionGeneration: 2)
        await fleet.refreshAll()
        #expect(fleet.leadChoice.current == nil)
        #expect(await fleet.chat.openLead(fleet: fleet, canControl: { _ in true }) == nil)
        #expect(older.ensureCalls == 0 && older.sent.isEmpty)
    }
    @Test("A failed snapshot after ensure stays an error, and retry GETs without another ensure")
    func failedSnapshot() async throws {
        let fleet = fleet(), client = client(existing: false)
        let snapshot = FirstMateDemo.chatWindowLead(), lead = summary(FirstMateDemo.chatWindowLead())
        client.snapshots = [:]
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshAll()
        client.lead = lead
        #expect(await fleet.chat.openLead(fleet: fleet, canControl: { _ in true }) == nil)
        #expect(fleet.chat.leadOpenError != nil && fleet.leadChoice.current == "alpha")
        client.snapshots = [snapshot.feature.id: snapshot]
        #expect(await fleet.chat.openLead(fleet: fleet)?.machineID == "alpha")
        #expect(client.ensureCalls == 1 && fleet.chat.leadOpenError == nil)
    }
    @Test("Held snapshot success/error cannot replace newer navigation or a changed source", arguments: [false, true], [false, true])
    func heldSnapshot(replace: Bool, fail: Bool) async throws {
        let fleet = fleet(), base = client(), gate = ChatTestGate()
        let client = LeadSnapshotGateClient(base: base, gate: gate, fail: fail)
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        let old = try #require(fleet.store(forMachineID: "alpha"))
        let opening = Task { await fleet.chat.openLead(fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        let next = FirstMateFeatureTarget(machineID: "alpha", featureID: "newer-feature")
        if replace { fleet.activate(sources: [source("alpha", base, token: "replacement")], connectionGeneration: 1) }
        else { #expect(fleet.open(next)) }
        await gate.open()
        #expect(await opening.value == nil)
        #expect(old.leadSnapshot == nil)
        #expect(fleet.chat.leadOpenError == nil, "Stale failure must not overwrite newer feedback")
        #expect(fleet.selectedTarget == (replace ? nil : next))
    }
    @Test("Phone pins, failed LIST threshold, all-down retention and recovery use shared choice")
    func choiceLifecycle() async throws {
        let fleet = fleet(), a = client(), b = client()
        fleet.activate(sources: [source("alpha", a), source("beta", b)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        #expect(fleet.leadChoice.current == "alpha", "Roster order breaks equal counts, no Mac local preference")
        fleet.chat.pin("missing"); #expect(fleet.leadChoice.current == "alpha")
        fleet.chat.pin("beta"); #expect(fleet.leadChoice.current == "beta")
        b.features = .failure(.server(status: 503, message: "Synthetic offline"))
        await fleet.refreshChatIndex(); #expect(fleet.leadChoice.current == "beta")
        await fleet.refreshChatIndex(); #expect(fleet.leadChoice.current == "alpha" && fleet.leadChoice.preferred == "beta")
        a.features = .failure(.server(status: 503, message: "Synthetic offline"))
        for _ in 0..<4 { await fleet.refreshChatIndex() }
        #expect(fleet.leadChoice.current == "beta")
        #expect(fleet.chat.index.hosts.allSatisfy { $0.failedPolls == 3 })
        a.features = .success([]); await fleet.refreshChatIndex(); #expect(fleet.leadChoice.current == "alpha")
        b.features = .success([]); await fleet.refreshChatIndex(); #expect(fleet.leadChoice.current == "beta")
        fleet.activate(sources: [source("alpha", a)], connectionGeneration: 1)
        #expect(fleet.leadChoice.current == "alpha")
        #expect(fleet.chat.pinnedMachineID == "beta", "Invalid pin follows shared policy without rewriting preference")
    }
    @Test("A failed lead summary is not a failed LIST poll and never triggers failover")
    func summaryFailure() async throws {
        let fleet = fleet(), a = client(), b = client(), gate = ChatTestGate()
        let wrapped = LeadSnapshotGateClient(base: b, gate: gate, fail: false)
        fleet.activate(sources: [source("alpha", a), source("beta", wrapped)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        fleet.chat.pin("beta")
        await wrapped.setLeadFailure(true)
        for _ in 0..<3 { await fleet.refreshChatIndex() }
        #expect(fleet.leadChoice.current == "beta" && !fleet.leadChoice.isFallback)
        #expect(fleet.chat.index.hosts.allSatisfy { $0.failedPolls == 0 })
        #expect(fleet.chat.index.hosts.first { $0.machineID == "beta" }?.lead != nil)
    }
    @Test("Context excludes own origin aliases and normalized peers, retains offline nonarchived features")
    func contextOrigins() async throws {
        let fleet = fleet(), a = client(), peer = client(), offline = client(), alias = client()
        let entry = ChatFixtures.entry("kept", hud: .blocked, unread: true)
        var archived = ChatFixtures.entry("archived", hud: .blocked, unread: true); archived.archivedAt = "2030-01-01T00:00:00Z"
        for client in [peer, offline, alias] { client.fleet = .success([entry, archived]) }
        var lead = try #require(a.lead)
        lead.peers = [.init(id: "not-beta", name: "Not a matching name", url: "https://BETA.example.invalid:443/")]
        a.lead = lead
        fleet.activate(sources: [source("alpha", a), source("beta", peer), source("offline", offline),
            source("alias", alias, url: ChatFixtures.machine("alpha").urlString)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        offline.features = .failure(.server(status: 503, message: "Synthetic offline"))
        await fleet.refreshChatIndex(); await fleet.refreshChatIndex()
        let context = try #require(fleet.chat.leadContext(machineID: "alpha", fleet: fleet))
        #expect(context.machines.map(\.name) == ["Offline Mac"])
        #expect(context.machines.first?.offline == true)
        #expect(context.machines.first?.features.count == 1)
    }
    @Test("Lead reservations and retry keep original owner, draft, request and nil/non-nil context", arguments: [false, true])
    func frozenSubmission(nilContext: Bool) async throws {
        let fleet = fleet(), a = client(), b = client(), gate = ChatTestGate()
        b.fleet = .success([ChatFixtures.entry("beta-feature", hud: .blocked, unread: true)])
        if nilContext {
            var lead = try #require(a.lead)
            lead.peers = [.init(id: "remote", name: "Peer", url: ChatFixtures.machine("beta").urlString)]
            a.lead = lead
        }
        fleet.activate(sources: [source("alpha", a), source("beta", b)], connectionGeneration: 1)
        await fleet.refreshAll()
        fleet.chat.pin("alpha")
        let target = try #require(await fleet.chat.openLead(fleet: fleet))
        let store = try #require(fleet.store(for: target))
        store.draft = "Frozen alpha prompt"
        let handle = try #require(FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: true))
        let context = store.outgoingMessage(handle)?.leadContext
        #expect((context == nil) == nilContext)
        store.draft = "New alpha draft"
        a.beforeSend = { await gate.wait(); throw URLError(.timedOut) }
        let sending = Task { await store.completeOutgoingMessage(handle) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        fleet.chat.pin("beta")
        let beta = try #require(await fleet.chat.openLead(fleet: fleet))
        let other = try #require(fleet.store(for: beta)); other.draft = "Beta only"
        await fleet.refreshChatIndex()
        #expect(a.sent.count == 1 && b.sent.isEmpty)
        #expect(store.draft == "New alpha draft" && other.draft == "Beta only")
        await gate.open(); _ = await sending.value
        #expect(fleet.chat.index.hosts.allSatisfy { $0.failedPolls == 0 }, "A real send timeout does not change LIST reachability")
        let failure = try #require(store.sendFailure(for: target.featureID))
        var changed = try #require(a.lead); changed.peers = []; a.lead = changed
        b.fleet = .success([ChatFixtures.entry("changed", hud: .working, unread: false)])
        await fleet.refreshChatIndex()
        fleet.chat.pin("alpha"); #expect(await fleet.chat.openLead(fleet: fleet) == target)
        a.beforeSend = nil
        let retry = try #require(FirstMateMobileSubmission.retryHandle(failure, store: store, target: target, fleet: fleet, canControl: true))
        await store.retryOutgoingMessage(retry)
        #expect(a.sentRequestIDs == [handle.requestID, handle.requestID])
        #expect(a.sent.allSatisfy { $0.text == "Frozen alpha prompt" && $0.featureID == target.featureID })
        #expect(a.sentContexts == (context.map { [$0, $0] } ?? []))
        #expect(b.sent.isEmpty && store.draft == "New alpha draft" && other.draft == "Beta only")
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ChatTestTimeout(description: "lead operation") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor LeadSnapshotGateClient: FirstMateClient {
    let base: SyntheticChatFleetClient
    let gate: ChatTestGate
    let fail: Bool
    private var leadFailure = false
    func setLeadFailure(_ value: Bool) { leadFailure = value }
    init(base: SyntheticChatFleetClient, gate: ChatTestGate, fail: Bool) { self.base = base; self.gate = gate; self.fail = fail }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { try await base.fetchFirstMateCapabilities() }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await base.fetchFirstMateFeatures() }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse { try await base.fetchFirstMateFleet() }
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse {
        if leadFailure { throw APIError.server(status: 503, message: "Synthetic summary failure") }
        return try await base.fetchFirstMateLead()
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        await gate.wait()
        if fail { throw APIError.server(status: 503, message: "Synthetic snapshot failure") }
        return try await base.fetchFirstMateFeature(id)
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
