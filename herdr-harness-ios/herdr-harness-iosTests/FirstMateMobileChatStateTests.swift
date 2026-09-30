import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Mobile chat fleet and lifecycle", .serialized)
@MainActor
struct FirstMateMobileChatStateTests {
    private func fleet() -> FirstMateMobileFleetStore {
        FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "MobileChat.\(UUID())")!)
    }
    private func source(_ id: String, _ client: SyntheticChatFleetClient, token: String = "token") -> FirstMateMobileFleetSource {
        let machine = ChatFixtures.machine(id)
        return .init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: token), client: client)
    }
    private func client(_ message: String = "m1") -> SyntheticChatFleetClient {
        SyntheticChatFleetClient(features: [ChatFixtures.feature("feature", status: "blocked")],
                                 fleet: [ChatFixtures.entry("feature", hud: .blocked, latestFirstMate: message)])
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "mobile condition") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Feature dots ignore search, scope and lead unread; older hosts keep attention dots")
    func badgeAndFallback() async throws {
        let fleet = fleet(), alpha = client(), beta = client("m2")
        beta.fleet = .success([ChatFixtures.entry("feature", hud: .working), ChatFixtures.entry("archived", hud: .blocked, archived: true)])
        let legacy = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1"]), features: [ChatFixtures.feature("feature", status: "blocked")])
        fleet.activate(sources: [source("alpha", alpha), source("beta", beta), source("legacy", legacy)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        #expect(fleet.badgeCount == 2)
        fleet.search = "nothing matches"
        fleet.selectScope(.machine("beta"))
        #expect(fleet.badgeCount == 2)
        #expect(fleet.conversations.count == 3)
        await fleet.chat.markRead(.init(machineID: "legacy", featureID: "feature"), through: "m1", fleet: fleet)
        #expect(legacy.reads.isEmpty && fleet.badgeCount == 2)
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: "feature"), through: "m1", fleet: fleet)
        #expect(fleet.badgeCount == 1)
        #expect(beta.reads.isEmpty)
    }

    @Test("A delayed failed marker cannot roll back a rotated connection's newer read")
    func readRotation() async throws {
        let fleet = fleet(), old = client(), replacement = client()
        let gate = ChatTestGate()
        old.read = { _, _ in await gate.wait(); throw APIError.server(status: 503, message: "Synthetic outage", code: "unavailable") }
        fleet.activate(sources: [source("alpha", old)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        let reading = Task { await fleet.chat.markRead(target, through: "m1", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        #expect(fleet.badgeCount == 0)
        fleet.activate(sources: [source("alpha", replacement, token: "rotated")], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        #expect(fleet.badgeCount == 1)
        await fleet.chat.markRead(target, through: "m1", fleet: fleet)
        await gate.open(); await reading.value
        #expect(fleet.badgeCount == 0)
        #expect(replacement.reads.count == 1)
        #expect(fleet.chat.readState.overrides[.init(machineID: "alpha", featureID: "feature")] == "m1")
    }

    @Test("A newer feature reply stays unread while an older marker completes")
    func newReplyDuringRead() async throws {
        let fleet = fleet(), client = client(), gate = ChatTestGate()
        client.read = { feature, message in
            await gate.wait()
            return .init(featureID: feature, readThroughMessageID: message, unread: false)
        }
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        let reading = Task { await fleet.chat.markRead(target, through: "m1", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        client.fleet = .success([ChatFixtures.entry("feature", hud: .blocked, latestFirstMate: "m2")])
        await fleet.refreshChatIndex()
        #expect(fleet.badgeCount == 1)
        await gate.open(); await reading.value
        #expect(fleet.badgeCount == 1)
        await fleet.chat.markRead(target, through: "m2", fleet: fleet)
        #expect(fleet.badgeCount == 0 && client.reads.count == 2)
    }

    @Test("Mobile markers roll back with bounded backoff; a new reply bypasses it")
    func readBackoff() async {
        let fleet = fleet(), client = client()
        client.read = { _, _ in throw APIError.server(status: 503, message: "Offline") }
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        var now = Date(timeIntervalSince1970: 1_900_000_000)
        fleet.chat.clock = { now }
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        for (index, delay) in [8, 16, 32, 64, 128, 180, 180].enumerated() {
            await fleet.chat.markRead(target, through: "m1", fleet: fleet)
            #expect(client.reads.count == index + 1 && fleet.badgeCount == 1)
            await fleet.chat.markRead(target, through: "m1", fleet: fleet)
            #expect(client.reads.count == index + 1)
            now.addTimeInterval(Double(delay))
        }
        await fleet.chat.markRead(target, through: "m2", fleet: fleet)
        #expect(client.reads.count == 8)
        await fleet.chat.markRead(target, through: "local-outgoing-synthetic", fleet: fleet)
        #expect(client.reads.count == 8)
    }

    private func leadClient() -> SyntheticChatFleetClient {
        let snapshot = FirstMateDemo.chatWindowLead()
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1"]))
        client.lead = .init(feature: snapshot.feature, unread: true, workingOnReply: false,
                            latestMessage: .init(id: "lead-m1", role: "assistant", text: "Synthetic", createdAt: nil),
                            machine: .init(id: "not-a-phone-machine", name: "Same display name"))
        client.snapshots = [snapshot.feature.id: snapshot]
        return client
    }

    @Test("Lead choice has no local Mac policy and ensure results stay on the captured owner")
    func leadOpening() async throws {
        let fleet = fleet(), alpha = leadClient(), beta = leadClient()
        fleet.activate(sources: [source("alpha", alpha), source("beta", beta)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        fleet.chat.pin("beta")
        #expect(fleet.leadChoice.current == "beta")
        #expect(await fleet.chat.openLead(fleet: fleet)?.machineID == "beta", "An existing lead is readable without mutation authority")
        #expect(alpha.ensureCalls == 0 && beta.ensureCalls == 0)
        let opened = await fleet.chat.openLead(fleet: fleet, canControl: { $0 == "beta" })
        #expect(opened?.machineID == "beta")
        #expect(alpha.ensureCalls == 0 && beta.ensureCalls == 0)
        _ = await fleet.chat.openLead(fleet: fleet, canControl: { _ in true })
        #expect(beta.ensureCalls == 0, "An existing lead is fetched, never unnecessarily ensured")
        #expect(alpha.sent.isEmpty && beta.sent.isEmpty)
        beta.features = .failure(.server(status: 503, message: "Offline"))
        await fleet.refreshChatIndex()
        #expect(fleet.leadChoice.current == "beta")
        await fleet.refreshChatIndex()
        #expect(fleet.leadChoice.current == "alpha" && fleet.leadChoice.isFallback)
        #expect(fleet.selectedTarget == opened, "Failover choice cannot migrate an open prompt/history")
        beta.features = .success([])
        await fleet.refreshChatIndex()
        #expect(fleet.leadChoice.current == "beta")
    }

    @Test("An old lead ensure cannot select over a new feature or replacement connection")
    func deferredLead() async throws {
        let fleet = fleet(), client = leadClient(), gate = ChatTestGate()
        client.beforeEnsure = { await gate.wait() }
        client.features = .success([ChatFixtures.feature("feature")])
        let ensuredLead = client.lead; client.lead = nil
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        client.lead = ensuredLead
        let opening = Task { await fleet.chat.openLead(fleet: fleet, canControl: { _ in true }) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        let feature = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        #expect(fleet.open(feature))
        await gate.open()
        #expect(await opening.value == nil)
        #expect(fleet.selectedTarget == feature && client.sent.isEmpty)
    }

    @Test("Lead unread is optimistic but a newer reply survives a delayed confirmation")
    func leadReadRace() async throws {
        let fleet = fleet(), client = leadClient(), gate = ChatTestGate()
        client.read = { feature, message in await gate.wait(); return .init(featureID: feature, readThroughMessageID: message, unread: false) }
        fleet.activate(sources: [source("alpha", client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        let id = try #require(client.lead?.feature.id)
        let reading = Task { await fleet.chat.markRead(.init(machineID: "alpha", featureID: id), through: "lead-m1", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait { await gate.arrived }
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        var lead = try #require(client.lead)
        lead.latestMessage?.id = "lead-m2"
        client.lead = lead
        await fleet.refreshChatIndex()
        await gate.open(); await reading.value
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        #expect(fleet.badgeCount == 0, "Lead unread never contributes to feature dots")
    }

    @Test("The app driver polls outside First Mate, stops on suspension, and preserves stores")
    func driverLifecycle() async throws {
        let fleet = fleet(), client = client()
        let sources = [source("alpha", client)]
        let driver = FirstMateFleetDriver(fleet: fleet)
        driver.fleetInterval = .milliseconds(20)
        let running = Task { await driver.observe(sources: sources, connectionGeneration: 1) }
        try await wait { client.featureListCalls >= 3 }
        let store = try #require(fleet.store(forMachineID: "alpha"))
        store.draft = "Retained on another tab"
        running.cancel(); await running.value
        let calls = client.featureListCalls
        try await Task.sleep(for: .milliseconds(60))
        #expect(client.featureListCalls == calls)
        let resumed = Task { await driver.observe(sources: sources, connectionGeneration: 1) }
        try await wait { client.featureListCalls > calls }
        resumed.cancel(); await resumed.value
        #expect(fleet.store(forMachineID: "alpha") === store)
        #expect(store.draft == "Retained on another tab")
    }

    @Test("A slow initial host does not delay a healthy host's feature badge")
    func independentInitialPublication() async throws {
        let fleet = fleet(), healthy = client(), slow = client()
        let gate = MobileCapabilityGate()
        slow.beforeCapabilities = { await gate.wait() }
        let driver = FirstMateFleetDriver(fleet: fleet)
        let running = Task { await driver.observe(sources: [source("healthy", healthy), source("slow", slow)], connectionGeneration: 1) }
        defer { running.cancel(); Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fleet.badgeCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fleet.badgeCount == 1, "Publish the healthy summary while the slow host is still held")
        #expect(await gate.arrivals > 0)
        running.cancel(); await gate.open(); await running.value
    }

    @Test("Selection wakes the slow loop and only the exact visible owner gets fast snapshots")
    func selectedDriver() async throws {
        let fleet = fleet(), alpha = client(), beta = client()
        let driver = FirstMateFleetDriver(fleet: fleet)
        driver.fleetInterval = .seconds(60)
        driver.selectedInterval = .milliseconds(20)
        driver.inactiveSelectionInterval = .seconds(60)
        let running = Task { await driver.observe(sources: [source("alpha", alpha), source("beta", beta)], connectionGeneration: 1) }
        defer { running.cancel() }
        try await wait { alpha.fleetCalls > 0 && beta.fleetCalls > 0 }
        let before = alpha.featureCalls, other = beta.featureCalls
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        #expect(fleet.open(target))
        driver.setVisibleTarget(target)
        try await wait { alpha.featureCalls >= before + 2 }
        #expect(beta.featureCalls == other)
        driver.setVisibleTarget(nil)
        try await Task.sleep(for: .milliseconds(30))
        let paused = alpha.featureCalls
        try await Task.sleep(for: .milliseconds(60))
        #expect(alpha.featureCalls == paused)
        running.cancel(); await running.value
    }

    @Test("Renaming and reordering preserve owners, read overrides and drafts")
    func presentationChanges() async throws {
        let fleet = fleet(), alpha = client(), beta = client()
        let sources = [source("alpha", alpha), source("beta", beta)]
        fleet.activate(sources: sources, connectionGeneration: 1)
        await fleet.refreshChatIndex()
        let store = try #require(fleet.store(forMachineID: "alpha"))
        store.draft = "Keep this draft"
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: "feature"), through: "m1", fleet: fleet)
        let calls = alpha.featureListCalls
        var renamed = ChatFixtures.machine("alpha")
        renamed.name = "Renamed synthetic host"
        fleet.updateMachineNames([renamed, ChatFixtures.machine("beta")])
        #expect(fleet.conversations.first(where: { $0.machineID == "alpha" })?.machineName == renamed.name)
        #expect(alpha.featureListCalls == calls)
        fleet.activate(sources: sources.reversed(), connectionGeneration: 1)
        #expect(fleet.store(forMachineID: "alpha") === store && store.draft == "Keep this draft")
        #expect(fleet.badgeCount == 1)
    }

    @Test("Synthetic app driver has a real lead and never uses the injected network client")
    func demoNeverNetworks() async {
        let fleet = fleet(), client = client()
        let driver = FirstMateFleetDriver(fleet: fleet)
        await driver.observe(sources: [.init(machine: ChatFixtures.machine("demo1"), configuration: nil, client: client, isDemo: true)], connectionGeneration: 1)
        #expect(client.featureListCalls == 0 && client.capabilityCalls == 0 && client.leadCalls == 0)
        #expect(fleet.conversations.contains { $0.featureID == "demo-receipts" })
        #expect(fleet.store(forMachineID: "demo1")?.leadSnapshot != nil)
        #expect(fleet.leadChoice.current == "demo1")
    }

    @Test("Control lease remains exact-store and stale cleanup cannot revoke a newer grant")
    func controlLease() throws {
        let first = FirstMateStore(), second = FirstMateStore()
        first.configure(client: nil, demo: true); second.configure(client: nil, demo: true)
        let old = FirstMateWorkspaceControlLease(), current = FirstMateWorkspaceControlLease()
        old.update(store: first, available: true)
        let lifecycle = first.lifecycle
        old.update(store: second, available: true)
        #expect(!first.controlAvailable && second.controlAvailable)
        old.release(storeID: ObjectIdentifier(first), lifecycleIdentity: lifecycle)
        #expect(second.controlAvailable)
        current.update(store: second, available: true)
        old.release()
        #expect(second.controlAvailable)
        current.release()
        #expect(!second.controlAvailable)
    }
}

/// Startup legitimately probes a host from the legacy store and shared index
/// concurrently. Keep every waiter so the fixture cannot lose a continuation.
private actor MobileCapabilityGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
