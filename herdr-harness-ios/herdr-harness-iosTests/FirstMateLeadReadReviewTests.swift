import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Lead assistant-marker review", .serialized)
@MainActor
struct FirstMateLeadReadReviewTests {
    private func snapshot() -> FirstMateSnapshot {
        let feature = FirstMateDemo.chatWindowLead().feature
        return .init(feature: feature, messages: [
            .init(id: "assistant-A", featureID: feature.id, role: "assistant", text: "Synthetic answer", status: "delivered", createdAt: "2030-01-01T00:00:00Z"),
            .init(id: "user-U", featureID: feature.id, role: "user", text: "Synthetic follow-up", status: "delivered", createdAt: "2030-01-01T00:00:01Z"),
        ])
    }
    private func client(_ snapshot: FirstMateSnapshot) -> SyntheticChatFleetClient {
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1"]))
        client.lead = .init(feature: snapshot.feature, unread: true, workingOnReply: false,
                            latestMessage: .init(id: "user-U", role: "user", text: "Synthetic follow-up", createdAt: "2030-01-01T00:00:01Z"))
        client.snapshots = [snapshot.feature.id: snapshot]
        return client
    }
    private func source(_ client: SyntheticChatFleetClient, token: String = "synthetic") -> FirstMateMobileFleetSource {
        let machine = ChatFixtures.machine("alpha")
        return .init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: token), client: client)
    }
    private func fleet(_ client: SyntheticChatFleetClient, snapshot: FirstMateSnapshot) async -> FirstMateMobileFleetStore {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "LeadReadReview.\(UUID())")!)
        fleet.activate(sources: [source(client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        fleet.store(forMachineID: "alpha")?.receive(snapshot)
        return fleet
    }
    private func wait(_ gate: ChatTestGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived) {
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "lead read review") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Assistant A is optimistically read even when user U is the latest conversation row")
    func userLatestAcknowledgement() async throws {
        let snapshot = snapshot(), client = client(snapshot), gate = ChatTestGate()
        client.read = { feature, marker in await gate.wait(); return .init(featureID: feature, readThroughMessageID: marker, unread: false) }
        let fleet = await fleet(client, snapshot: snapshot)
        let read = Task { await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-A", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait(gate)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        await gate.open(); await read.value
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        await fleet.refreshChatIndex() // The server summary has not caught up yet.
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        #expect(client.reads.map(\.messageID) == ["assistant-A"])
    }

    @Test("An old acknowledgement cannot hide a newer assistant behind another user row")
    func newerAssistant() async throws {
        var snapshot = snapshot()
        let client = client(snapshot), gate = ChatTestGate()
        client.read = { feature, marker in await gate.wait(); return .init(featureID: feature, readThroughMessageID: marker, unread: false) }
        let fleet = await fleet(client, snapshot: snapshot)
        let read = Task { await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-A", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait(gate)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        snapshot.feature.revision += 1
        snapshot.messages += [
            .init(id: "assistant-B", featureID: snapshot.feature.id, role: "assistant", text: "New answer", status: "delivered", createdAt: "2030-01-01T00:00:02Z"),
            .init(id: "user-V", featureID: snapshot.feature.id, role: "user", text: "Another follow-up", status: "delivered", createdAt: "2030-01-01T00:00:03Z"),
        ]
        fleet.store(forMachineID: "alpha")?.receive(snapshot)
        var lead = try #require(client.lead)
        lead.latestMessage = .init(id: "user-V", role: "user", text: "Another follow-up", createdAt: "2030-01-01T00:00:03Z")
        client.lead = lead
        await fleet.refreshChatIndex()
        await gate.open(); await read.value
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-B", fleet: fleet)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
    }

    @Test("A marker behind an already observed assistant cannot clear that reply")
    func alreadyNewerAssistant() async {
        var snapshot = snapshot()
        snapshot.messages.append(.init(id: "assistant-B", featureID: snapshot.feature.id, role: "assistant",
                                       text: "Already observed", status: "delivered", createdAt: "2030-01-01T00:00:02Z"))
        let client = client(snapshot), fleet = await fleet(client, snapshot: snapshot)
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-A", fleet: fleet)
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
    }

    @Test("After a confirming summary, a new unread transition is not hidden by the old user-row observation")
    func summaryConfirmation() async throws {
        let snapshot = snapshot(), client = client(snapshot), fleet = await fleet(client, snapshot: snapshot)
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-A", fleet: fleet)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        var lead = try #require(client.lead)
        lead.unread = false
        client.lead = lead
        await fleet.refreshChatIndex()
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        lead.unread = true // A new reply not yet available in the full snapshot.
        client.lead = lead
        await fleet.refreshChatIndex()
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
    }

    @Test("An unseen user-row advance remains conservative until the snapshot establishes the assistant identity")
    func userAdvance() async throws {
        var snapshot = snapshot()
        let client = client(snapshot), fleet = await fleet(client, snapshot: snapshot)
        await fleet.chat.markRead(.init(machineID: "alpha", featureID: snapshot.feature.id), through: "assistant-A", fleet: fleet)
        var lead = try #require(client.lead)
        lead.latestMessage = .init(id: "user-V", role: "user", text: "Later", createdAt: "2030-01-01T00:00:02Z")
        client.lead = lead
        await fleet.refreshChatIndex()
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        snapshot.feature.revision += 1
        snapshot.messages.append(.init(id: "user-V", featureID: snapshot.feature.id, role: "user", text: "Later",
                                       status: "delivered", createdAt: "2030-01-01T00:00:02Z"))
        fleet.store(forMachineID: "alpha")?.receive(snapshot)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
    }

    @Test("A failed user-latest lead marker rolls back and respects retry backoff")
    func failure() async throws {
        let snapshot = snapshot(), client = client(snapshot), gate = ChatTestGate()
        client.read = { _, _ in await gate.wait(); throw APIError.server(status: 503, message: "Synthetic refusal") }
        let fleet = await fleet(client, snapshot: snapshot)
        var now = Date(timeIntervalSince1970: 1_900_000_000)
        fleet.chat.clock = { now }
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: snapshot.feature.id)
        let read = Task { await fleet.chat.markRead(target, through: "assistant-A", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait(gate)
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        await gate.open(); await read.value
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        client.read = { feature, marker in .init(featureID: feature, readThroughMessageID: marker, unread: false) }
        await fleet.chat.markRead(target, through: "assistant-A", fleet: fleet)
        #expect(client.reads.count == 1)
        now.addTimeInterval(8)
        await fleet.chat.markRead(target, through: "assistant-A", fleet: fleet)
        #expect(client.reads.count == 2 && !fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
    }

    @Test("Old lead read failure cannot roll back a replacement connection's acknowledgement")
    func rotation() async throws {
        let snapshot = snapshot(), old = client(snapshot), replacement = client(snapshot), gate = ChatTestGate()
        old.read = { _, _ in await gate.wait(); throw APIError.server(status: 503, message: "Old refusal") }
        let fleet = await fleet(old, snapshot: snapshot)
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: snapshot.feature.id)
        let read = Task { await fleet.chat.markRead(target, through: "assistant-A", fleet: fleet) }
        defer { Task { await gate.open() } }
        try await wait(gate)
        fleet.activate(sources: [source(replacement, token: "replacement")], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        fleet.store(forMachineID: "alpha")?.receive(snapshot)
        #expect(fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        await fleet.chat.markRead(target, through: "assistant-A", fleet: fleet)
        await gate.open(); await read.value
        #expect(!fleet.chat.leadIsUnread(machineID: "alpha", fleet: fleet))
        #expect(replacement.reads.count == 1)
    }
}
