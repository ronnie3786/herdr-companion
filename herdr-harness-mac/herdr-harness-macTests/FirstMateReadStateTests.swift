import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate read markers")
@MainActor
struct FirstMateReadStateTests {
    private let id = FirstMateFleetFeatureID(machineID: "alpha", featureID: "waiting")

    @Test("A local read clears the chat until First Mate writes again")
    func pureReadState() {
        var state = FirstMateReadState()
        let entry = ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_1")
        #expect(state.isUnread(entry, machineID: "alpha"))
        state.markRead(id, messageID: "fmm_1")
        #expect(!state.isUnread(entry, machineID: "alpha"))
        #expect(state.isUnread(entry, machineID: "beta"), "Read state is per machine")

        let newer = ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_2")
        #expect(state.isUnread(newer, machineID: "alpha"), "A new First Mate message makes it unread again")
        #expect(!state.isUnread(ChatFixtures.entry("waiting", hud: .blocked, unread: false, latestFirstMate: "fmm_2"), machineID: "alpha"))
    }

    @Test("A rollback applies only while its own read is still current")
    func pureRollback() {
        var state = FirstMateReadState()
        state.markRead(id, messageID: "fmm_1")
        state.markRead(id, messageID: "fmm_2")
        state.rollBack(id, messageID: "fmm_1")
        #expect(state.overrides[id] == "fmm_2")
        state.rollBack(id, messageID: "fmm_2")
        #expect(state.overrides[id] == nil)
    }

    @Test("The dot clears before the post returns and comes back if the post fails")
    func optimisticThenRollback() async throws {
        let gate = ChatTestGate()
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_1")],
            read: { _, _ in
                await gate.wait()
                throw APIError.server(status: 500, message: "Read failed")
            }
        )
        let index = try await activatedIndex(client)
        #expect(index.badgeCount == 1)

        let read = Task { await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1") }
        try await ChatFixtures.waitUntil("read posted") { !client.reads.isEmpty }
        #expect(index.badgeCount == 0, "The dot clears at once")
        await gate.open()
        await read.value
        #expect(index.badgeCount == 1, "A failed post restores the dot")
        #expect(client.reads.map(\.messageID) == ["fmm_1"])
    }

    @Test("A late failure never rolls back a newer read")
    func staleRollbackIgnored() async throws {
        let gate = ChatTestGate()
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_2")]
        )
        client.read = { featureID, messageID in
            if messageID == "fmm_1" {
                await gate.wait()
                throw APIError.server(status: 500, message: "Slow failure")
            }
            return FirstMateReadResponse(featureID: featureID, readThroughMessageID: messageID, unread: false)
        }
        let index = try await activatedIndex(client)
        let slow = Task { await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1") }
        try await ChatFixtures.waitUntil("slow read posted") { client.reads.count == 1 }
        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_2")
        await gate.open()
        await slow.value
        #expect(index.readState.overrides[id] == "fmm_2")
        #expect(index.badgeCount == 0)
    }

    @Test("The companion's answer replaces a stale summary, and a later First Mate message is unread again")
    func successAndNewMessage() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_1")]
        )
        let index = try await activatedIndex(client)
        // The transcript already shows a newer First Mate message than the summary.
        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_2")
        #expect(index.hosts.first?.fleetEntries?["waiting"]?.unread == false)
        #expect(index.hosts.first?.fleetEntries?["waiting"]?.readThroughMessageID == "fmm_2")
        #expect(index.badgeCount == 0)

        client.fleet = .success([ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_3")])
        await index.refresh()
        #expect(index.badgeCount == 1, "A new First Mate message brings the dot back")
    }

    @Test("Already read, demo, and older hosts post nothing")
    func skippedPosts() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("read", status: "blocked")],
            fleet: [FirstMateFleetEntry(featureID: "read", title: "Read", status: "blocked", latestFirstMateMessageID: "fmm_1",
                                        readThroughMessageID: "fmm_1", unread: false)]
        )
        let legacy = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1"]),
                                              features: [ChatFixtures.feature("legacy", status: "blocked")])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client),
                                                 ChatFixtures.source("beta", client: legacy)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)

        await index.markRead(machineID: "alpha", featureID: "read", throughMessageID: "fmm_1")
        #expect(client.reads.isEmpty)
        #expect(index.readState.overrides.isEmpty)

        await index.markRead(machineID: "beta", featureID: "legacy", throughMessageID: "fmm_9")
        #expect(legacy.reads.isEmpty)

        await index.markRead(machineID: "demo", featureID: "demo-receipts", throughMessageID: "demo-receipts-message-3")
        #expect(index.readState.overrides[FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")] == "demo-receipts-message-3")

        // The same read again is a no-op.
        await index.markRead(machineID: "demo", featureID: "demo-receipts", throughMessageID: "demo-receipts-message-3")
        #expect(index.readState.overrides.count == 2)
        #expect(index.badgeCount == 1, "The older host still counts its needs-you feature")
    }

    @Test("A read after the index stops observing still reaches the companion")
    func readAfterDeactivate() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_1")]
        )
        let index = try await activatedIndex(client)
        index.deactivate()
        #expect(!index.hasObserver)

        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1")
        #expect(client.reads.map(\.messageID) == ["fmm_1"], "The marker is posted, not only hidden on this Mac")
        #expect(index.badgeCount == 0)
        #expect(index.hosts.first?.fleetEntries?["waiting"]?.unread == false)
    }

    private func activatedIndex(_ client: SyntheticChatFleetClient) async throws -> FirstMateFleetIndex {
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        try #require(index.hosts.first?.supportsFleet == true)
        return index
    }
}

@Suite("First Mate fleet index summary support")
@MainActor
struct FirstMateFleetIndexFleetTests {
    @Test("A supporting host is probed once per lifecycle and its summary fetched every refresh")
    func probeOncePerLifecycle() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("f1", status: "blocked")],
            fleet: [ChatFixtures.entry("f1", hud: .blocked, step: 3)]
        )
        let index = FirstMateFleetIndex()
        let source = ChatFixtures.source("alpha", client: client)
        let lifecycle = index.activate(sources: [source], connectionGeneration: 1)
        for _ in 0..<3 { await index.refresh(lifecycle: lifecycle) }
        #expect(client.capabilityCalls == 1)
        #expect(client.fleetCalls == 3)
        #expect(client.featureListCalls == 3)
        let host = try #require(index.hosts.first)
        #expect(host.supportsFleet)
        #expect(host.fleetEntries?["f1"]?.stepIndex == 3)

        let next = index.activate(sources: [source], connectionGeneration: 1)
        await index.refresh(lifecycle: next)
        #expect(client.capabilityCalls == 2, "A new lifecycle probes again")
        #expect(index.hosts.first?.fleetEntries?["f1"] != nil, "An unchanged host keeps its summary across activation")
    }

    @Test("An unsupported host is probed again only after five minutes")
    func unsupportedReprobe() async throws {
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1"]),
                                              features: [ChatFixtures.feature("f1", status: "awaiting_direction")])
        let index = FirstMateFleetIndex()
        let time = TestClock()
        index.clock = { time.now }
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        time.now += 120
        await index.refresh(lifecycle: lifecycle)
        #expect(client.capabilityCalls == 1)
        #expect(client.fleetCalls == 0)
        #expect(index.hosts.first?.supportsFleet == false)
        #expect(index.hosts.first?.fleetEntries == nil)

        client.capabilities = .success(["first-mate-v1", "first-mate-fleet-v1"])
        client.fleet = .success([ChatFixtures.entry("f1", hud: .ready)])
        time.now += 200
        await index.refresh(lifecycle: lifecycle)
        #expect(client.capabilityCalls == 2)
        #expect(index.hosts.first?.supportsFleet == true)
        #expect(index.hosts.first?.fleetEntries?["f1"]?.hudStatus == .ready)
    }

    @Test("A companion without the capability route reads as unsupported, not failed")
    func missingCapabilityRoute() async throws {
        let client = SyntheticChatFleetClient(capabilities: .failure(.server(status: 404, message: "Not found")),
                                              features: [ChatFixtures.feature("f1", status: "blocked")])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        await index.refresh(lifecycle: lifecycle)
        let host = try #require(index.hosts.first)
        #expect(host.error == nil)
        #expect(!host.unsupported)
        #expect(!host.supportsFleet)
        #expect(host.features.map(\.id) == ["f1"])
        #expect(client.capabilityCalls == 1)
        #expect(index.badgeCount == index.attentionCount)
    }

    @Test("A failed probe keeps the last answer and asks again next time")
    func failedProbe() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")],
                                              fleet: [ChatFixtures.entry("f1", hud: .blocked)])
        let index = FirstMateFleetIndex()
        let source = ChatFixtures.source("alpha", client: client)
        await index.refresh(lifecycle: index.activate(sources: [source], connectionGeneration: 1))
        client.capabilities = .failure(.server(status: 503, message: "Busy"))
        let lifecycle = index.activate(sources: [source], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        await index.refresh(lifecycle: lifecycle)
        #expect(client.capabilityCalls == 3)
        #expect(index.hosts.first?.supportsFleet == true)
        #expect(index.hosts.first?.fleetEntries?["f1"] != nil)
    }

    @Test("Summary changes publish; telemetry-only updates stay quiet")
    func contentRevision() async throws {
        let entry = ChatFixtures.entry("f1", hud: .working, latestFirstMate: "fmm_1", step: 1)
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "running")], fleet: [entry])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        let revision = index.contentRevision

        var touched = entry
        touched.updatedAt = "2030-01-01T10:00:01Z"
        client.fleet = .success([touched])
        await index.refresh(lifecycle: lifecycle)
        #expect(index.contentRevision == revision)

        var moved = entry
        moved.stepIndex = 2
        moved.now = "In review"
        client.fleet = .success([moved])
        await index.refresh(lifecycle: lifecycle)
        #expect(index.contentRevision == revision + 1)
        #expect(index.hosts.first?.fleetEntries?["f1"]?.stepIndex == 2)
    }

    @Test("Losing the capability drops the summary")
    func capabilityLost() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")],
                                              fleet: [ChatFixtures.entry("f1", hud: .blocked)])
        let index = FirstMateFleetIndex()
        let source = ChatFixtures.source("alpha", client: client)
        await index.refresh(lifecycle: index.activate(sources: [source], connectionGeneration: 1))
        client.capabilities = .success(["first-mate-v1"])
        await index.refresh(lifecycle: index.activate(sources: [source], connectionGeneration: 1))
        #expect(index.hosts.first?.supportsFleet == false)
        #expect(index.hosts.first?.fleetEntries == nil)
    }

    @Test("A fleet route that disappears mid-lifecycle falls back to the feature list")
    func fleetRouteRolledBack() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "running")],
                                              fleet: [ChatFixtures.entry("f1", hud: .blocked)])
        let index = FirstMateFleetIndex()
        let time = TestClock()
        index.clock = { time.now }
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        #expect(index.badgeCount == 1)

        client.fleet = .failure(.server(status: 404, message: "Not found"))
        await index.refresh(lifecycle: lifecycle)
        let host = try #require(index.hosts.first)
        #expect(!host.supportsFleet)
        #expect(host.fleetEntries == nil)
        #expect(host.error == nil)
        #expect(index.badgeCount == FirstMateAttention.count(hosts: index.hosts))
        #expect(index.badgeCount == 0, "The running feature no longer carries the stale blocked dot")

        await index.refresh(lifecycle: lifecycle)
        #expect(client.capabilityCalls == 1, "An unsupported answer waits for the reprobe interval")
        time.now += 301
        await index.refresh(lifecycle: lifecycle)
        #expect(client.capabilityCalls == 2)
    }

    @Test("A failing fleet request other than 404/501 keeps the last summary")
    func fleetTransientFailure() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")],
                                              fleet: [ChatFixtures.entry("f1", hud: .blocked)])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        client.fleet = .failure(.server(status: 503, message: "Busy"))
        await index.refresh(lifecycle: lifecycle)
        #expect(index.hosts.first?.supportsFleet == true)
        #expect(index.hosts.first?.fleetEntries?["f1"] != nil)
    }

    @Test("The capability probe runs alongside the feature list")
    func probeOverlapsFeatureList() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")],
                                              fleet: [ChatFixtures.entry("f1", hud: .blocked)])
        let overlap = ChatOverlapFlag()
        client.beforeCapabilities = { [client] in
            // A sequential refresh would never start the list while the
            // probe waits, so this would time out.
            for _ in 0..<400 where client.featureListCalls == 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
            overlap.set(client.featureListCalls > 0)
        }
        let index = FirstMateFleetIndex()
        await index.refresh(lifecycle: index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1))
        #expect(overlap.value)
        #expect(index.hosts.first?.supportsFleet == true)
        #expect(client.fleetCalls == 1)
    }

    @Test("A superseded observer returns at once, without waiting out its poll interval")
    func supersededObserverReturnsPromptly() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")])
        let index = FirstMateFleetIndex()
        index.pollingInterval = .seconds(60)
        let observer = Task { await index.observe(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1) }
        try await ChatFixtures.waitUntil("observing") { index.hasObserver && client.featureListCalls > 0 }
        let firstReturned = ChatOverlapFlag()
        Task { await observer.value; firstReturned.set(true) }
        index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 2)
        try await ChatFixtures.waitUntil("superseded observer returns", timeout: .seconds(2)) { firstReturned.value }

        let second = Task { await index.observe(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 3) }
        let secondReturned = ChatOverlapFlag()
        Task { await second.value; secondReturned.set(true) }
        try await ChatFixtures.waitUntil("observing again") { index.hasObserver }
        second.cancel()
        try await ChatFixtures.waitUntil("cancelling ends the observer's sleep", timeout: .seconds(2)) { secondReturned.value }
        #expect(!index.hasObserver)
    }
}

@Suite("First Mate read marker backoff")
@MainActor
struct FirstMateReadBackoffTests {
    @Test("A failing read is posted once per backoff window and the chat stays unread")
    func failedReadBacksOff() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked, latestFirstMate: "fmm_1")],
            read: { _, _ in throw APIError.server(status: 503, message: "Unavailable") }
        )
        let index = FirstMateFleetIndex()
        let time = TestClock()
        index.clock = { time.now }
        await index.refresh(lifecycle: index.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1))

        for _ in 0..<5 {
            await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1")
        }
        #expect(client.reads.count == 1, "The same marker is not posted again inside the backoff window")
        #expect(index.badgeCount == 1, "The dot stays honest")
        #expect(index.readState.overrides.isEmpty)

        time.now += FirstMateFleetIndex.readRetryInitialDelay + 1
        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1")
        #expect(client.reads.count == 2, "It is retried once the backoff expires")

        time.now += FirstMateFleetIndex.readRetryInitialDelay + 1
        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_1")
        #expect(client.reads.count == 2, "The backoff doubles")

        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_2")
        #expect(client.reads.count == 3, "A newer marker is posted at once")

        client.read = { featureID, messageID in
            FirstMateReadResponse(featureID: featureID, readThroughMessageID: messageID, unread: false)
        }
        time.now += FirstMateFleetIndex.readRetryInitialDelay + 1
        await index.markRead(machineID: "alpha", featureID: "waiting", throughMessageID: "fmm_2")
        #expect(client.reads.count == 4)
        #expect(index.badgeCount == 0)
    }
}

/// A flag a `@Sendable` test hook can set.
private final class ChatOverlapFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ value: Bool) { lock.withLock { _value = value } }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_900_000_000)
}
