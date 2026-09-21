import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@Suite("Chat tab color publisher", .serialized)
@MainActor
struct ChatTabColorPublisherTests {
    // MARK: - Opt-in and export

    @Test("Opting in publishes existing assignments with effective labels and unassigned tabs")
    func publishesExistingAssignments() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.sage, to: "\(machine.id)|w1:t1")
        model.chatTabColors.rename(.sage, to: "Synthetic Release Group")
        model.chatTabColors.assign(.iris, to: "\(machine.id)|w2:t1")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let storage = RecordingChatTabColorSecretStorage()
        let publisher = makePublisher(
            defaults: defaults,
            storage: storage,
            transport: transport
        )

        // Sharing is off by default and independent of agent control: binding
        // the model must not reach the network.
        publisher.configure(model: model)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transport.publicationList().isEmpty)
        #expect(!publisher.isPublishing)
        #expect(storage.values().isEmpty)

        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)
        let publication = try await requireLastPublication(transport)
        #expect(publication.clientId == publisher.clientID)
        #expect(publication.request.serverId == "srv_synthetic_alpha")
        #expect(publication.request.platform == "macos")
        #expect(publication.request.clientName == "Herdr Companion")
        #expect(publication.request.enabled)
        #expect(publication.request.revision == 1)
        #expect(publication.request.tabs.map(\.tabId) == ["w1:t1", "w1:t2", "w2:t1", "w3:t1"])

        let first = try #require(publication.request.tabs.first { $0.tabId == "w1:t1" })
        #expect(first.color == "sage")
        #expect(first.label == "Synthetic Release Group")
        let second = try #require(publication.request.tabs.first { $0.tabId == "w2:t1" })
        #expect(second.color == "iris")
        #expect(second.label == "Iris")
        let unassigned = try #require(publication.request.tabs.first { $0.tabId == "w3:t1" })
        #expect(unassigned.color == nil)
        #expect(unassigned.label == nil)
        #expect(unassigned.workspaceId == "w3")

        // The publisher credential is bound to the server and the stable
        // installation, in its own namespace.
        let account = ChatTabColorPublisherSecret.account(
            serverID: "srv_synthetic_alpha",
            clientID: publisher.clientID
        )
        #expect(storage.value(for: account)?.count == 64)
        #expect(storage.value(for: "agent-control.receiver.srv_synthetic_alpha.\(publisher.clientID)") == nil)
        publisher.stopForTesting()
    }

    @Test("Every palette value publishes with its effective label")
    func allPaletteValuesPublish() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        let workspace = try #require(DemoData.workspaces.first).stamped(machineID: machine.id)
        model.workspaces = [workspace]

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)

        for (index, color) in ChatTabColor.allCases.enumerated() {
            model.chatTabColors.assign(color, to: "\(machine.id)|\(workspace.workspaceID):t1")
            let expectedRevision = index + 1
            try await transport.waitForPublicationCount(expectedRevision)
            let publication = try await requireLastPublication(transport)
            #expect(publication.request.revision == expectedRevision)
            let row = try #require(publication.request.tabs.first { $0.tabId == "w1:t1" })
            #expect(row.color == color.rawValue)
            #expect(row.label == color.defaultLabel)
        }
        publisher.stopForTesting()
    }

    @Test("Renaming and removing a color changes every affected tab on the next revision")
    func renameAndRemoval() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.sage, to: "\(machine.id)|w1:t1")
        model.chatTabColors.assign(.sage, to: "\(machine.id)|w1:t2")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        model.chatTabColors.rename(.sage, to: "Renamed Workstream")
        try await transport.waitForPublicationCount(2)
        let renamed = try await requireLastPublication(transport)
        #expect(renamed.request.revision == 2)
        #expect(renamed.request.tabs.filter { $0.color == "sage" }.allSatisfy { $0.label == "Renamed Workstream" })

        model.chatTabColors.assign(nil, to: "\(machine.id)|w1:t1")
        try await transport.waitForPublicationCount(3)
        let removed = try await requireLastPublication(transport)
        #expect(removed.request.revision == 3)
        let clearedTab = try #require(removed.request.tabs.first { $0.tabId == "w1:t1" })
        #expect(clearedTab.color == nil)
        #expect(clearedTab.label == nil)
        publisher.stopForTesting()
    }

    @Test("An unchanged snapshot refreshes as an equal-revision heartbeat")
    func heartbeatReusesRevision() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.clay, to: "\(machine.id)|w2:t1")

        let clock = MutableClock(Date(timeIntervalSince1970: 2_000_000_000))
        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transport,
            now: { clock.now }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        // Not yet due, so the unchanged snapshot is not resent.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.publicationList().count == 1)

        clock.now = clock.now.addingTimeInterval(21)
        try await transport.waitForPublicationCount(2)
        let publications = await transport.publicationList()
        let first = try #require(publications.first)
        let second = try #require(publications.dropFirst().first)
        #expect(first.request.revision == 1)
        #expect(second.request.revision == 1)
        #expect(second.request.tabs == first.request.tabs)
        #expect(second.request.publisherToken == first.request.publisherToken)
        publisher.stopForTesting()
    }

    // MARK: - Revisions, relaunch, and races

    @Test("A relaunch continues a monotonic revision and reuses the per-server secret")
    func relaunchRevision() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.slate, to: "\(machine.id)|w1:t1")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let storage = RecordingChatTabColorSecretStorage()
        let firstPublisher = makePublisher(defaults: defaults, storage: storage, transport: transport)
        firstPublisher.configure(model: model)
        firstPublisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)
        let first = try await requireLastPublication(transport)
        #expect(first.request.revision == 1)
        firstPublisher.stopForTesting()

        let secondPublisher = makePublisher(defaults: defaults, storage: storage, transport: transport)
        secondPublisher.configure(model: model)
        model.chatTabColors.rename(.slate, to: "Relaunched Workstream")
        try await transport.waitForPublicationCount(2)
        let second = try await requireLastPublication(transport)
        #expect(second.request.revision == 2)
        #expect(second.request.publisherToken == first.request.publisherToken)
        #expect(second.request.tabs.first { $0.tabId == "w1:t1" }?.label == "Relaunched Workstream")
        secondPublisher.stopForTesting()
    }

    @Test("Disabling sends a revisioned clear without touching local assignments")
    func disableClearsRemotely() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.rose, to: "\(machine.id)|w1:t1")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        publisher.setSharingEnabled(false)
        try await transport.waitForPublicationCount(2)
        try await waitForPublicationRecord(publisher) { !$0.enabled && !$0.pendingClear }
        let clear = try await requireLastPublication(transport)
        #expect(clear.request.enabled == false)
        #expect(clear.request.tabs.isEmpty)
        #expect(clear.request.revision == 2)
        #expect(model.chatTabColors.color(for: "\(machine.id)|w1:t1") == .rose)
        let record = try #require(publisher.publicationRecords.values.first)
        #expect(record.enabled == false)
        #expect(record.pendingClear == false)
        #expect(record.revision == 2)
        publisher.stopForTesting()
    }

    @Test("A pending clear survives an offline host and is retried when it returns")
    func pendingClearRetriesWhenReachable() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        await transport.setCapabilitiesFailure("Synthetic offline")
        publisher.setSharingEnabled(false)
        try await transport.waitForCapabilityCount(2)
        try await waitForPublicationRecord(publisher) { $0.pendingClear }
        #expect(publisher.hostStates.first?.phase == .pendingClear)
        let pending = try #require(publisher.publicationRecords.values.first)
        #expect(pending.pendingClear)

        await transport.setCapabilitiesFailure(nil)
        try await transport.waitForPublicationCount(2)
        try await waitForPublicationRecord(publisher) { !$0.pendingClear }
        let clear = try await requireLastPublication(transport)
        #expect(clear.request.enabled == false)
        #expect(clear.request.revision == 2)
        let settled = try #require(publisher.publicationRecords.values.first)
        #expect(settled.pendingClear == false)
        publisher.stopForTesting()
    }

    @Test("A delayed publish cannot restore older values after disabling")
    func delayedPublicationVersusDisable() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.iris, to: "\(machine.id)|w1:t1")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        await transport.setBlocksPublications(true)
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        publisher.setSharingEnabled(false)
        try await transport.waitForPublicationCount(2)
        let pending = await transport.publicationList()
        let published = try #require(pending.first)
        let clear = try #require(pending.dropFirst().first)
        #expect(published.request.enabled)
        #expect(clear.request.enabled == false)
        #expect(clear.request.revision > published.request.revision)
        #expect(published.request.revision == 1)
        #expect(clear.request.revision == 2)
        await transport.releasePublications()
        publisher.stopForTesting()
    }

    // MARK: - Identity, topology, and isolation

    @Test("Duplicate aliases with conflicting assignments pause publication instead of choosing")
    func duplicateAliases() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let aliasA = HerdrMachine(id: "alias-a", name: "Alias A", urlString: "https://alias-a.example.invalid")
        let aliasB = HerdrMachine(id: "alias-b", name: "Alias B", urlString: "https://alias-b.example.invalid")
        let model = makeModel(defaults: defaults, machines: [aliasA, aliasB])
        model.machineStates[aliasA.id] = .live
        model.machineStates[aliasB.id] = .live
        model.workspaces = (
            DemoData.workspaces.map { $0.stamped(machineID: aliasA.id) }
                + DemoData.workspaces.map { $0.stamped(machineID: aliasB.id) }
        )
        model.chatTabColors.assign(.sage, to: "\(aliasA.id)|w1:t1")
        model.chatTabColors.assign(.rose, to: "\(aliasB.id)|w1:t1")

        let transportA = ChatTabColorTestTransport(serverID: "srv_shared")
        let transportB = ChatTabColorTestTransport(serverID: "srv_shared")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transportA,
            transportFactory: { configuration in
                configuration.baseURL.host == "alias-b.example.invalid" ? transportB : transportA
            }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transportA.waitForCapabilityCount(1)
        try await transportB.waitForCapabilityCount(1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await transportA.publicationList().isEmpty)
        #expect(await transportB.publicationList().isEmpty)
        #expect(publisher.hostStates.count == 2)
        #expect(publisher.hostStates.allSatisfy { $0.phase == .ambiguous })

        // Aligning the aliases resolves the ambiguity without inventing an
        // order-based winner. Either alias's transport may own the send.
        model.chatTabColors.assign(.sage, to: "\(aliasB.id)|w1:t1")
        try await waitForAnyPublication([transportA, transportB])
        let received = await transportA.publicationList() + transportB.publicationList()
        let publication = try #require(received.first)
        #expect(publication.request.serverId == "srv_shared")
        #expect(publication.request.tabs.first { $0.tabId == "w1:t1" }?.color == "sage")
        publisher.stopForTesting()
    }

    @Test("Identical raw tab IDs on two servers and two machines stay separate")
    func machineIsolation() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machineA = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let machineB = HerdrMachine(id: "synthetic-b", name: "Synthetic B", urlString: "https://synthetic-b.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machineA, machineB])
        model.machineStates[machineA.id] = .live
        model.machineStates[machineB.id] = .live
        model.workspaces = (
            DemoData.workspaces.map { $0.stamped(machineID: machineA.id) }
                + DemoData.secondaryWorkspaces.map { $0.stamped(machineID: machineB.id) }
        )
        model.chatTabColors.assign(.sage, to: "\(machineA.id)|w1:t1")
        model.chatTabColors.assign(.rose, to: "\(machineB.id)|w1:t1")

        let transportA = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let transportB = ChatTabColorTestTransport(serverID: "srv_synthetic_beta")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transportA,
            transportFactory: { configuration in
                configuration.baseURL.host == "synthetic-b.example.invalid" ? transportB : transportA
            }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transportA.waitForPublicationCount(1)
        try await transportB.waitForPublicationCount(1)

        let publicationA = try await requireLastPublication(transportA)
        let publicationB = try await requireLastPublication(transportB)
        #expect(publicationA.request.serverId == "srv_synthetic_alpha")
        #expect(publicationB.request.serverId == "srv_synthetic_beta")
        #expect(publicationA.request.tabs.first { $0.tabId == "w1:t1" }?.color == "sage")
        #expect(publicationB.request.tabs.first { $0.tabId == "w1:t1" }?.color == "rose")
        // Only the destination companion's rows are sent.
        #expect(publicationA.request.tabs.allSatisfy { $0.color != "rose" })
        #expect(publicationA.request.tabs.first { $0.tabId == "w2:t1" }?.color == nil)
        publisher.stopForTesting()
    }

    @Test("A disconnected or failed topology read never publishes an empty replacement")
    func topologyFailureDoesNotClear() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }
        model.chatTabColors.assign(.clay, to: "\(machine.id)|w1:t1")

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)

        model.machineStates[machine.id] = .disconnected
        try await Task.sleep(for: .milliseconds(60))
        #expect(await transport.publicationList().count == 1)
        #expect(publisher.hostStates.first?.phase == .waitingForConnection)

        model.machineStates[machine.id] = .live
        await transport.setCapabilitiesFailure("Synthetic topology read failed")
        try await Task.sleep(for: .milliseconds(60))
        #expect(await transport.publicationList().count == 1)
        #expect(publisher.publicationRecords.values.first?.enabled == true)
        publisher.stopForTesting()
    }

    @Test("An upgraded-required companion reports unsupported and never publishes")
    func unsupportedCompanion() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha", supportsPublication: false)
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForCapabilityCount(1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transport.publicationList().isEmpty)
        #expect(publisher.hostStates.first?.phase == .unsupported)
        #expect(publisher.hostStates.first?.detail.contains("Update this companion") == true)
        publisher.stopForTesting()
    }

    @Test("A stale connection generation never exports cached topology to the replacement server")
    func staleGenerationIsAbandoned() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Before", urlString: "https://before.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }

        let oldTransport = ChatTabColorTestTransport(serverID: "srv_before")
        let replacementTransport = ChatTabColorTestTransport(serverID: "srv_after")
        await oldTransport.setBlocksCapabilities(true)
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: oldTransport,
            transportFactory: { configuration in
                configuration.baseURL.host == "after.example.invalid" ? replacementTransport : oldTransport
            }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await oldTransport.waitForCapabilityCount(1)

        #expect(model.updateMachine(
            id: machine.id,
            name: "After",
            urlString: "https://after.example.invalid",
            token: "synthetic-token-after"
        ))
        await oldTransport.releaseCapabilities()
        try await replacementTransport.waitForCapabilityCount(1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await oldTransport.publicationList().isEmpty)
        #expect(await replacementTransport.publicationList().isEmpty)
        #expect(publisher.hostStates.first?.phase == .waitingForConnection)

        // Only a successful topology refresh for the replacement endpoint may
        // make the cached workspace identities publishable.
        let configuration = try #require(model.firstMateConfiguration(machineID: machine.id))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ChatTabColorTopologyURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        try await model.refresh(
            machineID: machine.id,
            using: client,
            expectedGeneration: model.connectionGeneration
        )
        try await replacementTransport.waitForPublicationCount(1)
        let publication = try await requireLastPublication(replacementTransport)
        #expect(publication.request.serverId == "srv_after")
        #expect(publication.request.enabled)
        #expect(await oldTransport.publicationList().isEmpty)
        publisher.stopForTesting()
    }

    @Test("A previously ambiguous alias that goes offline still blocks publication")
    func failedAliasStillBlocksPublication() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let aliasA = HerdrMachine(id: "alias-a", name: "Alias A", urlString: "https://alias-a.example.invalid")
        let aliasB = HerdrMachine(id: "alias-b", name: "Alias B", urlString: "https://alias-b.example.invalid")
        let model = makeModel(defaults: defaults, machines: [aliasA, aliasB])
        model.machineStates[aliasA.id] = .live
        model.machineStates[aliasB.id] = .live
        model.workspaces = (
            DemoData.workspaces.map { $0.stamped(machineID: aliasA.id) }
                + DemoData.workspaces.map { $0.stamped(machineID: aliasB.id) }
        )
        model.chatTabColors.assign(.sage, to: "\(aliasA.id)|w1:t1")
        model.chatTabColors.assign(.rose, to: "\(aliasB.id)|w1:t1")

        let transportA = ChatTabColorTestTransport(serverID: "srv_shared")
        let transportB = ChatTabColorTestTransport(serverID: "srv_shared")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transportA,
            transportFactory: { configuration in
                configuration.baseURL.host == "alias-b.example.invalid" ? transportB : transportA
            }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transportA.waitForCapabilityCount(1)
        try await transportB.waitForCapabilityCount(1)
        try await waitForHostPhase(publisher, .ambiguous)
        #expect(await transportA.publicationList().isEmpty)
        #expect(await transportB.publicationList().isEmpty)

        // Alias B stops answering after both identities were established. The
        // remaining reachable alias must not publish its conflicting view just
        // because the other alias is unavailable.
        await transportB.setCapabilitiesFailure("Synthetic offline")
        try await transportB.waitForCapabilityCount(3)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await transportA.publicationList().isEmpty)
        #expect(publisher.hostStates.count == 2)
        #expect(publisher.hostStates.allSatisfy { $0.phase == .ambiguous })

        // Restoring the alias with matching assignments publishes again.
        await transportB.setCapabilitiesFailure(nil)
        model.chatTabColors.assign(.sage, to: "\(aliasB.id)|w1:t1")
        try await waitForAnyPublication([transportA, transportB])
        publisher.stopForTesting()
    }

    @Test("Withdrawal fails over from an offline alias to a reachable one")
    func withdrawalFailsOverBetweenAliases() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let aliasA = HerdrMachine(id: "alias-a", name: "Alias A", urlString: "https://alias-a.example.invalid")
        let aliasB = HerdrMachine(id: "alias-b", name: "Alias B", urlString: "https://alias-b.example.invalid")
        let model = makeModel(defaults: defaults, machines: [aliasA, aliasB])
        model.machineStates[aliasA.id] = .live
        model.machineStates[aliasB.id] = .live
        model.workspaces = (
            DemoData.workspaces.map { $0.stamped(machineID: aliasA.id) }
                + DemoData.workspaces.map { $0.stamped(machineID: aliasB.id) }
        )

        let transportA = ChatTabColorTestTransport(serverID: "srv_shared")
        let transportB = ChatTabColorTestTransport(serverID: "srv_shared")
        // Alias B starts offline, so the first publication can only go through
        // the first configured alias, A.
        await transportB.setCapabilitiesFailure("Synthetic offline")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transportA,
            transportFactory: { configuration in
                configuration.baseURL.host == "alias-b.example.invalid" ? transportB : transportA
            }
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transportA.waitForPublicationCount(1)
        #expect(await transportB.publicationList().isEmpty)

        // B returns and authenticates as the same companion. The unchanged
        // snapshot stays a heartbeat, so A is still the last transport used.
        await transportB.setCapabilitiesFailure(nil)
        try await transportB.waitForCapabilityCount(2)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transportB.publicationList().isEmpty)

        // A goes offline before the user turns sharing off. The clear must fail
        // over to B instead of being stuck on the unreachable first alias.
        await transportA.setCapabilitiesFailure("Synthetic offline")
        publisher.setSharingEnabled(false)
        try await transportB.waitForPublicationCount(1)
        try await waitForPublicationRecord(publisher) { !$0.enabled && !$0.pendingClear }
        let lastPublished = await transportB.lastPublication()
        let clear = try #require(lastPublished)
        #expect(clear.request.enabled == false)
        #expect(clear.request.tabs.isEmpty)
        #expect(clear.request.revision > 1)
        publisher.stopForTesting()
    }

    @Test("A failed publication waits for the retry backoff before trying again")
    func publicationFailureBacksOff() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        await transport.setPublicationFailure("Synthetic publication failure")
        let publisher = makePublisher(
            defaults: defaults,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transport,
            retryBase: .milliseconds(150),
            retryMaximum: .milliseconds(150)
        )
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)
        try await waitForHostPhase(publisher, .failed)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transport.publicationList().count == 1)

        await transport.setPublicationFailure(nil)
        try await transport.waitForPublicationCount(2)
        let publication = try await requireLastPublication(transport)
        #expect(publication.request.enabled)
        try await waitForHostPhase(publisher, .shared)
        publisher.stopForTesting()
    }

    @Test("A mismatched publish response is rejected rather than recorded as shared")
    func mismatchedResponseRejected() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let model = makeModel(defaults: defaults, machines: [machine])
        model.machineStates[machine.id] = .live
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machine.id) }

        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        await transport.setPublishServerID("srv_somewhere_else")
        let publisher = makePublisher(defaults: defaults, storage: RecordingChatTabColorSecretStorage(), transport: transport)
        publisher.configure(model: model)
        publisher.setSharingEnabled(true)
        try await transport.waitForPublicationCount(1)
        try await waitForHostPhase(publisher, .failed)
        #expect(publisher.publicationRecords.values.allSatisfy { $0.lastPublishedAt == nil })
        publisher.stopForTesting()
    }

    @Test("Demo mode never creates a task, transport, or publisher secret")
    func demoIsolation() async throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "herdr.chatTabColors.share.v1")
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: defaults
        )
        let transport = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let storage = RecordingChatTabColorSecretStorage()
        let publisher = makePublisher(defaults: defaults, storage: storage, transport: transport)
        publisher.configure(model: model)
        #expect(!publisher.isPublishing)
        #expect(publisher.statusText.contains("demo"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await transport.capabilityCount() == 0)
        #expect(storage.values().isEmpty)
    }

    @Test("Publication never imports or rewrites either local store")
    func twoStoreIsolation() async throws {
        let (suiteA, defaultsA) = makeDefaults()
        let (suiteB, defaultsB) = makeDefaults()
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let machineA = HerdrMachine(id: "synthetic-a", name: "Synthetic A", urlString: "https://synthetic-a.example.invalid")
        let machineB = HerdrMachine(id: "synthetic-b", name: "Synthetic B", urlString: "https://synthetic-b.example.invalid")
        let modelA = makeModel(defaults: defaultsA, machines: [machineA])
        let modelB = makeModel(defaults: defaultsB, machines: [machineB])
        modelA.machineStates[machineA.id] = .live
        modelB.machineStates[machineB.id] = .live
        modelA.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machineA.id) }
        modelB.workspaces = DemoData.workspaces.map { $0.stamped(machineID: machineB.id) }
        modelA.chatTabColors.assign(.sage, to: "\(machineA.id)|w1:t1")
        modelA.chatTabColors.rename(.sage, to: "Store A Workstream")

        let transportA = ChatTabColorTestTransport(serverID: "srv_synthetic_alpha")
        let transportB = ChatTabColorTestTransport(serverID: "srv_synthetic_beta")
        let publisherA = makePublisher(defaults: defaultsA, storage: RecordingChatTabColorSecretStorage(), transport: transportA)
        let publisherB = makePublisher(
            defaults: defaultsB,
            storage: RecordingChatTabColorSecretStorage(),
            transport: transportB,
            transportFactory: { _ in transportB }
        )
        let beforeA = defaultsA.dictionary(forKey: "herdr.chatTabColors.v1")
        let beforeB = defaultsB.dictionary(forKey: "herdr.chatTabColors.v1")
        publisherA.configure(model: modelA)
        publisherB.configure(model: modelB)
        publisherA.setSharingEnabled(true)
        try await transportA.waitForPublicationCount(1)
        try await Task.sleep(for: .milliseconds(40))

        #expect(canonicalJSON(defaultsA.dictionary(forKey: "herdr.chatTabColors.v1")) == canonicalJSON(beforeA))
        #expect(canonicalJSON(defaultsB.dictionary(forKey: "herdr.chatTabColors.v1")) == canonicalJSON(beforeB))
        #expect(modelB.chatTabColors.color(for: "\(machineB.id)|w1:t1") == nil)
        #expect(await transportB.publicationList().isEmpty)
        #expect(publisherB.statusText == "Tab color sharing is off")
        publisherA.stopForTesting()
        publisherB.stopForTesting()
    }

    // MARK: - Fixtures

    private func makeDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "ChatTabColorPublisherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    private func makeModel(defaults: UserDefaults, machines: [HerdrMachine]) -> HerdrAppModel {
        let credentials = TestCredentialStore()
        for machine in machines {
            credentials.values["api-token.\(machine.id)"] = "synthetic-token-\(machine.id)"
        }
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: machines
        )
        model.hasCompletedSetup = true
        for machine in machines {
            model.confirmTopologyForTesting(machineID: machine.id)
        }
        return model
    }

    private func makePublisher(
        defaults: UserDefaults,
        storage: RecordingChatTabColorSecretStorage,
        transport: ChatTabColorTestTransport,
        heartbeatInterval: TimeInterval = 20,
        retryBase: Duration = .milliseconds(1),
        retryMaximum: Duration = .milliseconds(4),
        now: @escaping () -> Date = Date.init,
        transportFactory: ChatTabColorPublisher.TransportFactory? = nil
    ) -> ChatTabColorPublisher {
        ChatTabColorPublisher(
            defaults: defaults,
            secretStorage: storage,
            pollInterval: .milliseconds(5),
            heartbeatInterval: heartbeatInterval,
            retryBase: retryBase,
            retryMaximum: retryMaximum,
            allowsPublicationInUnitTests: true,
            now: now,
            transportFactory: transportFactory ?? { _ in transport }
        )
    }

    private func requireLastPublication(
        _ transport: ChatTabColorTestTransport
    ) async throws -> ChatTabColorTestTransport.Publication {
        let publication = await transport.lastPublication()
        return try #require(publication)
    }

    private func waitForHostPhase(
        _ publisher: ChatTabColorPublisher,
        _ phase: ChatTabColorPublisher.HostState.Phase
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while publisher.hostStates.first?.phase != phase {
            if ContinuousClock.now > deadline {
                throw ChatTabColorTestTransport.WaitError.exceededBound
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForAnyPublication(_ transports: [ChatTabColorTestTransport]) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            var count = 0
            for transport in transports {
                count += await transport.publicationList().count
            }
            if count > 0 { return }
            if ContinuousClock.now > deadline {
                throw ChatTabColorTestTransport.WaitError.exceededBound
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForPublicationRecord(
        _ publisher: ChatTabColorPublisher,
        _ predicate: @escaping (ChatTabColorPublicationRecord) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !publisher.publicationRecords.values.contains(where: predicate) {
            if ContinuousClock.now > deadline {
                throw ChatTabColorTestTransport.WaitError.exceededBound
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func canonicalJSON(_ object: Any?) -> Data? {
        guard let object else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Deterministic doubles

/// Deterministic fleet response used only to confirm a machine's topology
/// through the real `HerdrAppModel.refresh` path.
final class ChatTabColorTopologyURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = Data(
            """
            {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"idle","panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"idle","revision":1}]}],"alerts":[]}
            """.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MutableClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

final class RecordingChatTabColorSecretStorage: AgentControlSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(for account: String) -> AgentControlSecretRead {
        lock.lock()
        defer { lock.unlock() }
        guard let value = stored[account] else {
            return AgentControlSecretRead(status: errSecItemNotFound, value: nil)
        }
        return AgentControlSecretRead(status: errSecSuccess, value: value)
    }

    func set(_ value: String, for account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        stored[account] = value
        return errSecSuccess
    }

    func value(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored[account]
    }

    func values() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

actor ChatTabColorTestTransport: ChatTabColorTransport {
    struct Publication: Equatable, Sendable {
        let clientId: String
        let request: ChatTabColorPublicationRequest
    }

    enum WaitError: Error { case exceededBound }

    private var serverID: String
    private var publishServerID: String?
    private var supportsPublication: Bool
    private var capabilitiesFailure: String?
    private var publicationFailure: String?
    private var blocksCapabilities = false
    private var blocksPublications = false
    private var capabilityContinuations: [CheckedContinuation<Void, Never>] = []
    private var publicationContinuations: [CheckedContinuation<Void, Never>] = []
    private var capabilityRequests = 0
    private var publications: [Publication] = []

    init(serverID: String, supportsPublication: Bool = true) {
        self.serverID = serverID
        self.supportsPublication = supportsPublication
    }

    func setCapabilitiesFailure(_ message: String?) { capabilitiesFailure = message }
    func setPublicationFailure(_ message: String?) { publicationFailure = message }
    func setPublishServerID(_ value: String?) { publishServerID = value }
    func setBlocksCapabilities(_ value: Bool) { blocksCapabilities = value }
    func setBlocksPublications(_ value: Bool) { blocksPublications = value }

    func capabilities() async throws -> ChatTabColorCapabilitiesResponse {
        capabilityRequests += 1
        if blocksCapabilities {
            await withCheckedContinuation { capabilityContinuations.append($0) }
        }
        if let capabilitiesFailure {
            throw APIError.server(status: 503, message: capabilitiesFailure)
        }
        return ChatTabColorCapabilitiesResponse(
            ok: true,
            version: 1,
            serverId: serverID,
            capabilities: supportsPublication
                ? ["agent-control-v1", "discovery-v1", "chat-tab-colors-v1"]
                : ["agent-control-v1", "discovery-v1"],
            chatTabColorStaleAfterSeconds: 60
        )
    }

    func publish(
        clientId: String,
        request: ChatTabColorPublicationRequest
    ) async throws -> ChatTabColorPublicationResponse {
        publications.append(Publication(clientId: clientId, request: request))
        if blocksPublications {
            await withCheckedContinuation { publicationContinuations.append($0) }
        }
        if let publicationFailure {
            throw APIError.server(status: 503, message: publicationFailure)
        }
        return ChatTabColorPublicationResponse(
            ok: true,
            serverId: publishServerID ?? serverID,
            publication: ChatTabColorPublicationSummary(
                clientId: clientId,
                platform: request.platform,
                clientName: request.clientName,
                enabled: request.enabled,
                revision: request.revision,
                tabCount: request.tabs.count,
                updatedAt: "2030-01-01T00:00:00Z",
                lastSeenAt: "2030-01-01T00:00:00Z",
                stale: false
            )
        )
    }

    func releaseCapabilities() {
        let continuations = capabilityContinuations
        capabilityContinuations = []
        for continuation in continuations { continuation.resume() }
    }

    func releasePublications() {
        let continuations = publicationContinuations
        publicationContinuations = []
        for continuation in continuations { continuation.resume() }
    }

    func capabilityCount() -> Int { capabilityRequests }
    func publicationList() -> [Publication] { publications }
    func lastPublication() -> Publication? { publications.last }

    func waitForCapabilityCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while capabilityRequests < expected {
            if ContinuousClock.now > deadline { throw WaitError.exceededBound }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForPublicationCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while publications.count < expected {
            if ContinuousClock.now > deadline { throw WaitError.exceededBound }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
