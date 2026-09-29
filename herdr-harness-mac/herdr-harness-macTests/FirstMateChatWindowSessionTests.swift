import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate chat window session", .serialized)
@MainActor
struct FirstMateChatWindowSessionTests {
    @Test("Demo mode shows one synthetic host with the seven-feature chat demo")
    func demoHost() throws {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        #expect(session.isDemo)
        let host = try #require(session.hosts.first)
        #expect(session.hosts.count == 1)
        #expect(host.machineID == "demo")
        #expect(host.machineName == "This Mac")
        #expect(host.supportsFleet)
        #expect(host.features.count == 7)
        #expect(session.conversations.count == 7)
        #expect(session.badgeCount == 3)
        #expect(!session.showsMachineNames)
        #expect(session.conversations.filter(\.showsDot).map(\.featureID).sorted() == ["demo-receipts", "demo-release", "demo-search"])
        #expect(session.store(for: "demo") === session.store(for: "demo"))
        #expect(session.store(for: "demo")?.features.count == 7)
        #expect(session.store(for: "elsewhere") == nil)
    }

    @Test("Archiving a conversation removes its row and badge and returns the selected chat to My First Mate")
    func archiveConversation() async throws {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        let id = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
        session.select(.feature(id))
        session.requestArchive(id)
        let target = try #require(session.archiveCandidate)
        #expect(await session.archive(target, reason: nil) == nil)
        #expect(session.selection == .lead)
        #expect(session.conversations.count == 6)
        #expect(!session.conversations.contains { $0.id == id })
        #expect(session.badgeCount == 2)
        let store = try #require(session.store(for: "demo"))
        #expect(store.snapshots[id.featureID]?.feature.isArchived == true)
        await store.refresh()
        #expect(!session.conversations.contains { $0.id == id })
        #expect(await store.setArchived(featureID: id.featureID, archived: false))
        #expect(session.conversations.contains { $0.id == id })
    }

    @Test("Archiving an unselected row preserves the current conversation")
    func archiveUnselectedConversation() async throws {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        let selected = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-release")
        let archived = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
        session.select(.feature(selected))
        session.requestArchive(archived)
        let target = try #require(session.archiveCandidate)
        #expect(await session.archive(target, reason: nil) == nil)
        #expect(session.selection == .feature(selected))
        #expect(!session.conversations.contains { $0.id == archived })
    }

    @Test("Selecting in the window never moves the main window's selection, and the reverse")
    func selectionIndependence() throws {
        let model = ChatFixtures.model(demo: true)
        let shell = ChatFixtures.shell()
        shell.configureFirstMateIfNeeded(configuration: nil, connectionGeneration: model.connectionGeneration, isDemo: true)
        let mainSelection = try #require(shell.firstMate.selectedFeatureID)
        let mainInspector = shell.firstMate.inspector

        let session = FirstMateChatWindowSession(model: model, shell: shell)
        let receipts = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
        session.select(.feature(receipts))
        let store = try #require(session.selectedStore)
        #expect(store !== shell.firstMate)
        #expect(store.selectedFeatureID == "demo-receipts")
        #expect(session.selectedConversation?.title == "Receipt export")
        #expect(session.selectedSnapshot?.feature.id == "demo-receipts")
        #expect(shell.firstMate.selectedFeatureID == mainSelection)

        session.open(.agent(featureID: "demo-release", assignmentID: "demo-release-crew-2"), machineID: "demo")
        #expect(store.selectedFeatureID == "demo-release")
        #expect(store.inspector == .agents)
        #expect(session.inspectorPreference == true)
        #expect(shell.firstMate.selectedFeatureID == mainSelection)
        #expect(shell.firstMate.inspector == mainInspector)

        shell.firstMate.select("demo-search")
        shell.firstMate.inspector = .workflow
        #expect(store.selectedFeatureID == "demo-release")
        #expect(store.inspector == .agents)

        session.open(.feature(featureID: "demo-receipts"), machineID: "demo")
        #expect(store.inspector == .overview, "Opening another chat starts on Overview")
        // My First Mate is the lead First Mate: a chat in the same machine
        // store, so selecting it moves that store's chat and never the main window's.
        session.select(.lead)
        #expect(session.selectedStore === store)
        #expect(store.selectedFeatureID == store.leadFeatureID)
        #expect(store.leadFeatureID == "demo-lead")
        #expect(shell.firstMate.selectedFeatureID == "demo-search")
        session.select(.feature(receipts))
        #expect(store.selectedFeatureID == "demo-receipts")
    }

    @Test("Each machine gets its own store, rebuilt only when its connection changes")
    func storePerMachine() throws {
        let model = ChatFixtures.model(demo: false)
        let state = StoreTestState()
        let session = FirstMateChatWindowSession(
            model: model,
            shell: ChatFixtures.shell(),
            configuration: { machineID in
                state.tokens[machineID].flatMap { ServerConfiguration(urlString: "https://\(machineID).example.invalid", token: $0) }
            },
            makeClient: { _ in
                state.clientsMade += 1
                return SyntheticChatFleetClient()
            }
        )
        let alpha = try #require(session.store(for: "alpha"))
        let beta = try #require(session.store(for: "beta"))
        #expect(alpha !== beta)
        #expect(session.store(for: "alpha") === alpha)
        #expect(session.store(for: "gamma") == nil)
        #expect(state.clientsMade == 2)

        alpha.select("synthetic")
        state.tokens["alpha"] = "rotated-token"
        let rebuilt = try #require(session.store(for: "alpha"))
        #expect(rebuilt !== alpha)
        #expect(rebuilt.selectedFeatureID == nil)
        #expect(session.store(for: "beta") === beta)
        #expect(state.clientsMade == 3)
    }

    @Test("The conversation list and badge come from the shared fleet index, filtered locally")
    func liveHostsAndSearch() async throws {
        let shell = ChatFixtures.shell()
        let alpha = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("f1", title: "Receipt export", status: "blocked")],
            fleet: [FirstMateFleetEntry(featureID: "f1", title: "Receipt export", status: "blocked", latestFirstMateMessageID: "fmm_1",
                                        unread: true, activityAt: "2030-01-01T10:00:00Z")]
        )
        let beta = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1"]),
                                            features: [ChatFixtures.feature("f2", title: "Offline sync", status: "running")])
        let lifecycle = shell.firstMateFleet.activate(sources: [ChatFixtures.source("alpha", client: alpha),
                                                               ChatFixtures.source("beta", client: beta)], connectionGeneration: 1)
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: false), shell: shell,
                                                 configuration: { _ in nil }, makeClient: { _ in SyntheticChatFleetClient() })
        #expect(session.conversations.count == 2)
        #expect(session.badgeCount == 1)
        #expect(session.badgeCount == shell.firstMateFleet.badgeCount)
        #expect(session.showsMachineNames)

        session.search = "beta mac"
        #expect(session.filteredConversations.map(\.featureID) == ["f2"])
        session.search = "receipt"
        #expect(session.filteredConversations.map(\.featureID) == ["f1"])
        #expect(shell.firstMateFleet.search.isEmpty, "The main window's fleet search is untouched")
    }

    @Test("Submitting a prompt shows the row as working until First Mate replies")
    func submittedPromptProgress() async throws {
        let (shell, session, client, store, lifecycle) = try await blockedConversation()
        let id = FirstMateFleetFeatureID(machineID: "alpha", featureID: "f1")
        let original = try #require(session.conversations.first { $0.id == id })
        #expect(original.hudStatus == .blocked)
        #expect(original.showsDot)
        #expect(session.badgeCount == 1)

        var response = try #require(store.snapshots["f1"])
        response.messages.append(FirstMateMessage(id: "um_2", featureID: "f1", role: "user",
                                                  text: "Synthetic direction", status: "processing",
                                                  createdAt: "2030-01-01T10:01:00Z"))
        client.snapshots["f1"] = response
        let gate = ChatTestGate()
        client.beforeSend = { await gate.wait() }
        let handle = try #require(store.beginOutgoingMessage("Synthetic direction", expectedContext: store.operationContext))
        let send = Task { await store.completeOutgoingMessage(handle) }
        try await ChatFixtures.waitUntil("send reached companion") { client.sent.count == 1 }
        let sending = try #require(session.conversations.first { $0.id == id })
        #expect(sending.hudStatus == .working)
        #expect(sending.isWorkingOnReply)
        #expect(!sending.showsDot)
        #expect(session.badgeCount == 0)
        #expect(FirstMateChatSidebar.subtitle(featureCount: 1, needCount: session.badgeCount) == "1 feature, 0 need you")
        #expect(shell.firstMateFleet.badgeCount == 1, "The shared fleet badge remains authoritative")

        await gate.open()
        _ = await send.value
        let bridged = try #require(session.conversations.first { $0.id == id })
        #expect(bridged.hudStatus == .working)
        #expect(bridged.isWorkingOnReply)
        #expect(!bridged.showsDot)
        #expect(store.snapshots["f1"]?.messages.last?.id == "um_2")

        var fleet = try #require(try client.fleet.get().first)
        fleet.workingOnReply = true
        client.fleet = .success([fleet])
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        #expect(session.conversations.first { $0.id == id }?.hudStatus == .working)
        #expect(session.badgeCount == 0)

        // A different selected chat must not be required for the original
        // feature's local progress to retire on the next fleet reply.
        session.select(.lead)
        var feature = try #require(try client.features.get().first)
        feature.status = "awaiting_direction"
        feature.updatedAt = "2030-01-01T10:05:00Z"
        client.features = .success([feature])
        fleet.status = "awaiting_direction"
        fleet.hudStatus = .turn
        fleet.latestFirstMateMessageID = "fmm_3"
        fleet.unread = true
        fleet.workingOnReply = false
        fleet.activityAt = "2030-01-01T10:05:00Z"
        client.fleet = .success([fleet])
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        let replied = try #require(session.conversations.first { $0.id == id })
        #expect(replied.hudStatus == .turn)
        #expect(!replied.isWorkingOnReply)
        #expect(replied.showsDot)
        #expect(session.badgeCount == 1)
        #expect(store.snapshots["f1"]?.messages.last?.id == "um_2", "The unselected store still holds the old echo")
    }

    @Test("A receipt-only send retires its working row after a reply, even when selection changes before a snapshot poll")
    func switchedAwayFromReceiptOnlySend() async throws {
        let (shell, session, client, store, lifecycle) = try await blockedConversation()
        let id = FirstMateFleetFeatureID(machineID: "alpha", featureID: "f1")
        var receiptFeature = try #require(store.snapshots["f1"]?.feature)
        receiptFeature.updatedAt = "2030-01-01T10:01:00Z"
        var receipt = FirstMateSnapshot(feature: receiptFeature)
        receipt.hasDetails = false // POST returns only {ok, feature, message}, not the conversation arrays.
        receipt.message = FirstMateMessage(id: "um_2", featureID: "f1", role: "user",
                                           text: "Synthetic direction", status: "processing",
                                           createdAt: "2030-01-01T10:01:00Z")
        client.snapshots["f1"] = receipt

        let handle = try #require(store.beginOutgoingMessage("Synthetic direction", expectedContext: store.operationContext))
        #expect(session.conversations.first { $0.id == id }?.hudStatus == .working)
        _ = await store.completeOutgoingMessage(handle)
        #expect(store.outgoingMessages(for: "f1").first?.state == .acceptedAwaitingSnapshot(messageID: "um_2"))
        #expect(store.isAwaitingSendResolution(featureID: "f1"))
        #expect(store.snapshots["f1"]?.messages.map(\.id) == ["fmm_1"], "A mutation receipt does not update the cached messages")
        #expect(session.conversations.first { $0.id == id }?.hudStatus == .working)
        #expect(session.conversations.first { $0.id == id }?.showsDot == false)
        #expect(session.badgeCount == 0)

        session.select(.lead) // The window now polls only the lead, not f1.
        var feature = try #require(try client.features.get().first)
        feature.status = "awaiting_direction"
        feature.updatedAt = "2030-01-01T10:05:00Z"
        client.features = .success([feature])
        var fleet = try #require(try client.fleet.get().first)
        fleet.status = "awaiting_direction"
        fleet.hudStatus = .turn
        fleet.latestFirstMateMessageID = "fmm_3"
        fleet.unread = true
        fleet.workingOnReply = false
        fleet.activityAt = "2030-01-01T10:05:00Z"
        client.fleet = .success([fleet])
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)

        let replied = try #require(session.conversations.first { $0.id == id })
        #expect(replied.hudStatus == .turn)
        #expect(!replied.isWorkingOnReply)
        #expect(replied.showsDot)
        #expect(session.badgeCount == 1)
        #expect(store.isAwaitingSendResolution(featureID: "f1"), "The unselected store was never refreshed")
    }

    @Test("A rejected send restores the waiting badge at once")
    func rejectedPrompt() async throws {
        let (_, session, client, store, _) = try await blockedConversation()
        client.beforeSend = { throw APIError.server(status: 403, message: "Synthetic rejection") }
        let handle = try #require(store.beginOutgoingMessage("Synthetic direction", expectedContext: store.operationContext))
        #expect(session.conversations.first { $0.featureID == "f1" }?.hudStatus == .working)
        _ = await store.completeOutgoingMessage(handle)
        #expect(store.sendFailure(for: "f1") != nil)
        let row = try #require(session.conversations.first { $0.featureID == "f1" })
        #expect(row.hudStatus == .blocked)
        #expect(row.showsDot)
        #expect(session.badgeCount == 1)
    }

    @Test("A conversation without a window store is never projected")
    func fleetWithoutWindowStore() async throws {
        let shell = ChatFixtures.shell()
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("f1", status: "blocked")],
            fleet: [ChatFixtures.entry("f1", hud: .blocked, latestFirstMate: "fmm_1")]
        )
        let lifecycle = shell.firstMateFleet.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        let state = StoreTestState()
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: false), shell: shell,
                                                 configuration: { _ in nil }, makeClient: { _ in
                                                     state.clientsMade += 1
                                                     return SyntheticChatFleetClient()
                                                 })
        let expected = FirstMateConversationList.build(hosts: shell.firstMateFleet.hosts, readState: shell.firstMateFleet.readState)
        #expect(session.conversations == expected)
        #expect(session.conversations == expected, "A cached read must not create a store either")
        #expect(state.clientsMade == 0)
        #expect(session.badgeCount == shell.firstMateFleet.badgeCount)

        // The fleet's own reply flag still changes the row, without creating
        // a local store or changing the process-wide badge.
        var entry = try #require(try client.fleet.get().first)
        entry.workingOnReply = true
        client.fleet = .success([entry])
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        let working = try #require(session.conversations.first)
        #expect(working.hudStatus == .working)
        #expect(working.isWorkingOnReply)
        #expect(!working.showsDot)
        #expect(session.badgeCount == 0)
        #expect(shell.firstMateFleet.badgeCount == 1)
        #expect(state.clientsMade == 0)
    }

    private func blockedConversation() async throws -> (HerdrShellState, FirstMateChatWindowSession,
                                                        SyntheticChatFleetClient, FirstMateStore, Int) {
        let shell = ChatFixtures.shell()
        var feature = ChatFixtures.feature("f1", title: "Receipt export", status: "blocked")
        feature.updatedAt = "2030-01-01T10:00:00Z"
        let snapshot = FirstMateSnapshot(feature: feature, messages: [
            FirstMateMessage(id: "fmm_1", featureID: "f1", role: "assistant", text: "Awaiting direction",
                             status: "delivered", createdAt: "2030-01-01T10:00:00Z")
        ])
        let client = SyntheticChatFleetClient(
            features: [feature],
            fleet: [FirstMateFleetEntry(featureID: "f1", title: feature.title, status: "blocked",
                                        hudStatus: .blocked, latestFirstMateMessageID: "fmm_1", unread: true,
                                        activityAt: "2030-01-01T10:00:00Z")]
        )
        client.snapshots["f1"] = snapshot
        let lifecycle = shell.firstMateFleet.activate(sources: [ChatFixtures.source("alpha", client: client)], connectionGeneration: 1)
        await shell.firstMateFleet.refresh(lifecycle: lifecycle)
        let session = FirstMateChatWindowSession(
            model: ChatFixtures.model(demo: false), shell: shell,
            configuration: { $0 == "alpha" ? ServerConfiguration(urlString: "https://alpha.example.invalid", token: "synthetic") : nil },
            makeClient: { _ in client }
        )
        session.select(.feature(FirstMateFleetFeatureID(machineID: "alpha", featureID: "f1")))
        let store = try #require(session.selectedStore)
        await store.refresh()
        #expect(store.snapshots["f1"]?.messages.map(\.id) == ["fmm_1"])
        return (shell, session, client, store, lifecycle)
    }

    @Test("A demo chat read in a key window at the bottom clears its dot locally")
    func demoMarkRead() async throws {
        let shell = ChatFixtures.shell()
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: shell)
        let receipts = try #require(session.conversations.first { $0.featureID == "demo-receipts" })
        let newest = try #require(session.store(for: "demo")?.snapshots["demo-receipts"]?.messages.last?.id)

        session.markReadIfNeeded(featureID: "demo-receipts", machineID: "demo", newestMessageID: newest, isKeyWindow: false, isAtBottom: true)
        session.markReadIfNeeded(featureID: "demo-receipts", machineID: "demo", newestMessageID: newest, isKeyWindow: true, isAtBottom: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.badgeCount == 3)

        session.markReadIfNeeded(featureID: "demo-receipts", machineID: "demo", newestMessageID: newest, isKeyWindow: true, isAtBottom: true)
        try await ChatFixtures.waitUntil("demo read applied") { session.badgeCount == 2 }
        #expect(shell.firstMateFleet.readState.overrides[receipts.id] == receipts.latestFirstMateMessageID)
        #expect(session.conversations.first { $0.featureID == "demo-receipts" }?.showsDot == false)
    }

    @Test("While running, only the selected store refreshes and holds the control lease")
    func runRefreshesSelectedStore() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked"), ChatFixtures.feature("f2", status: "running")])
        let other = SyntheticChatFleetClient(features: [ChatFixtures.feature("g1", status: "running")])
        let session = FirstMateChatWindowSession(
            model: ChatFixtures.model(demo: false),
            shell: ChatFixtures.shell(),
            configuration: { ServerConfiguration(urlString: "https://\($0).example.invalid", token: "t") },
            makeClient: { $0.baseURL.host == "alpha.example.invalid" ? client : other }
        )
        _ = session.store(for: "beta")
        let task = Task { await session.run() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.featureListCalls == 0, "Nothing refreshes while the lead is selected")

        session.select(.feature(FirstMateFleetFeatureID(machineID: "alpha", featureID: "f2")))
        try await ChatFixtures.waitUntil("selected store refreshed") { client.featureCalls > 0 }
        let store = try #require(session.store(for: "alpha"))
        #expect(store.selectedFeatureID == "f2")
        #expect(store.controlAvailable)
        #expect(other.featureListCalls == 0)
        task.cancel()
        await task.value
        #expect(!store.controlAvailable, "Stopping releases the lease")
    }

    @Test("A mutation refreshes the main window's store for that machine and the fleet index")
    func didMutateRefreshesMainWindow() async throws {
        let model = ChatFixtures.model(demo: false)
        let shell = ChatFixtures.shell()
        let mainClient = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")])
        shell.configureFirstMateIfNeeded(
            machineID: "alpha",
            configuration: ServerConfiguration(urlString: "https://alpha.example.invalid", token: "t"),
            connectionGeneration: model.connectionGeneration,
            isDemo: false,
            client: mainClient
        )
        let fleetClient = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked")])
        let lifecycle = shell.firstMateFleet.activate(sources: [ChatFixtures.source("alpha", client: fleetClient)], connectionGeneration: 1)
        _ = lifecycle
        let session = FirstMateChatWindowSession(model: model, shell: shell, configuration: { _ in nil },
                                                 makeClient: { _ in SyntheticChatFleetClient() })
        session.didMutate(machineID: "alpha")
        try await ChatFixtures.waitUntil("main store refreshed") { mainClient.featureListCalls > 0 }
        try await ChatFixtures.waitUntil("fleet refreshed") { fleetClient.featureListCalls > 0 }
        #expect(shell.firstMate.features.map(\.id) == ["f1"])
    }

    @Test("A running window observes the fleet only while no other window does")
    func keepsFleetObserved() async throws {
        let shell = ChatFixtures.shell()
        let fleet = shell.firstMateFleet
        func client() -> SyntheticChatFleetClient {
            SyntheticChatFleetClient(
                features: [ChatFixtures.feature("f1", title: "Receipt export", status: "blocked")],
                fleet: [ChatFixtures.entry("f1", hud: .blocked, latestFirstMate: "fmm_1")]
            )
        }
        let windowClient = client()
        let session = FirstMateChatWindowSession(
            model: ChatFixtures.model(demo: false), shell: shell,
            configuration: { _ in nil }, makeClient: { _ in SyntheticChatFleetClient() },
            fleetSources: { [ChatFixtures.source("alpha", client: windowClient)] }
        )
        #expect(!fleet.hasObserver)
        let run = Task { await session.run() }
        defer { run.cancel() }
        try await ChatFixtures.waitUntil("window observes the fleet") { fleet.hasObserver && session.badgeCount == 1 }

        // The main window's observer takes over and the window leaves it alone.
        let mainClient = client()
        let main = Task { await fleet.observe(sources: [ChatFixtures.source("alpha", client: mainClient)], connectionGeneration: 1) }
        try await ChatFixtures.waitUntil("main window observes") { mainClient.featureListCalls > 0 && fleet.hasObserver }
        #expect(session.badgeCount == 1, "The hosts survive the hand-over")

        // Closing the main window hands observation back to the chat window.
        let windowCalls = windowClient.featureListCalls
        main.cancel()
        await main.value
        try await ChatFixtures.waitUntil("window observes again") { fleet.hasObserver && windowClient.featureListCalls > windowCalls }

        run.cancel()
        await run.value
        #expect(!fleet.hasObserver, "Closing the window stops its own observer")
    }

    @Test("Demo sends are stamped after the chat's newest message and move the chat to the top")
    func demoSendMovesChat() async throws {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        let store = try #require(session.store(for: "demo"))
        let first = try #require(session.conversations.first)
        let last = try #require(session.conversations.last)
        #expect(first.id != last.id)
        let seededNewest = try #require(store.snapshots[last.featureID]?.messages.last?.createdAt)

        session.select(.feature(last.id))
        store.draft = "Synthetic follow-up"
        await store.send()

        let messages = try #require(store.snapshots[last.featureID]?.messages)
        #expect(messages.suffix(2).map(\.role) == ["user", "assistant"])
        let sent = try #require(messages.last.flatMap { HerdrTimestamp.date(from: $0.createdAt) })
        let seeded = try #require(HerdrTimestamp.date(from: seededNewest))
        #expect(sent > seeded)
        #expect(messages.last?.createdAt != FirstMateDemo.timestamp)
        #expect(session.conversations.first?.id == last.id)
    }

    @Test("A Dock request waiting for the window opens its chat")
    func pendingOpen() {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        let target = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-search")
        session.pendingOpen = target
        session.applyPendingOpen()
        #expect(session.selection == .feature(target))
        #expect(session.pendingOpen == nil)
        #expect(session.selectedStore?.selectedFeatureID == "demo-search")
        #expect(session.skimState(for: target) === session.skimState(for: target))
    }

    @Test("A store rebuilt for a connection change keeps the open chat and loads it")
    func rebuiltStoreKeepsSelection() async throws {
        let model = ChatFixtures.model(demo: false)
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("alpha-first", status: "running"),
                                                         ChatFixtures.feature("beta", status: "blocked")])
        let session = FirstMateChatWindowSession(
            model: model, shell: ChatFixtures.shell(),
            configuration: { ServerConfiguration(urlString: "https://\($0).example.invalid", token: "t") },
            makeClient: { _ in client }
        )
        let beta = FirstMateFleetFeatureID(machineID: "alpha", featureID: "beta")
        session.select(.feature(beta))
        let original = try #require(session.selectedStore)
        await original.refresh()
        #expect(session.selectedSnapshot?.feature.id == "beta")

        model.connectionGeneration += 1
        let rebuilt = try #require(session.selectedStore)
        #expect(rebuilt !== original)
        #expect(rebuilt.selectedFeatureID == "beta", "The rebuilt store starts on the open chat")
        await rebuilt.refresh()
        #expect(session.selectedStore?.selectedFeatureID == "beta")
        #expect(session.selectedSnapshot?.feature.id == "beta")
    }

    @Test("Pointer choices focus the new chat's composer; keyboard moves never do")
    func composerFocusFollowsPointerOnly() {
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        #expect(session.pendingComposerFocus, "The window opens with its composer focused")
        session.pendingComposerFocus = false
        let receipts = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
        let search = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-search")

        // ↑/↓ through the list.
        session.select(.feature(receipts))
        #expect(!session.pendingComposerFocus)

        // A row click, then a keyboard move before that composer appeared.
        session.select(.feature(search), focusComposer: true)
        #expect(session.pendingComposerFocus)
        session.select(.feature(receipts))
        #expect(!session.pendingComposerFocus, "A keyboard move cancels a pending pointer focus")

        // Clicking the chat already open changes nothing to wait for.
        session.select(.feature(receipts), focusComposer: true)
        #expect(!session.pendingComposerFocus)

        session.open(.feature(featureID: "demo-release"), machineID: "demo")
        #expect(session.pendingComposerFocus, "A capsule is a pointer choice")
        session.pendingComposerFocus = false
        session.select(.lead, focusComposer: true)
        #expect(session.pendingComposerFocus, "The ＋ focuses My First Mate's composer")
    }

    @Test("My First Mate cannot start a feature without a machine and says so")
    func beginCreateWithoutMachine() {
        let session = FirstMateChatWindowSession(
            model: ChatFixtures.model(demo: false), shell: ChatFixtures.shell(),
            configuration: { _ in nil }, makeClient: { _ in SyntheticChatFleetClient() }
        )
        #expect(session.createMachineIDs.isEmpty)
        #expect(!session.beginCreate(goal: "A synthetic feature"))
        #expect(session.createStore == nil)
        #expect(session.createGoal.isEmpty)
        #expect(!FirstMateChatComposer.noMachineHint.isEmpty)

        let demo = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        #expect(demo.beginCreate(goal: "A synthetic feature"))
        #expect(demo.createStore != nil)
        demo.endCreate()
    }

    @Test("The refresh loop wakes at once on a selection change")
    func refreshWakesOnSelection() async throws {
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1", status: "blocked"), ChatFixtures.feature("f2", status: "running")])
        let session = FirstMateChatWindowSession(
            model: ChatFixtures.model(demo: false), shell: ChatFixtures.shell(),
            configuration: { ServerConfiguration(urlString: "https://\($0).example.invalid", token: "t") },
            makeClient: { _ in client }
        )
        let run = Task { await session.run() }
        defer { run.cancel() }
        session.select(.feature(FirstMateFleetFeatureID(machineID: "alpha", featureID: "f1")))
        try await ChatFixtures.waitUntil("first chat refreshed", timeout: .seconds(1)) { client.featureListCalls > 0 }
        try await Task.sleep(for: .milliseconds(50))
        let firstPass = client.featureListCalls
        session.select(.feature(FirstMateFleetFeatureID(machineID: "alpha", featureID: "f2")))
        try await ChatFixtures.waitUntil("second chat refreshed before the 2 s interval", timeout: .seconds(1)) {
            client.featureListCalls > firstPass
        }
        session.select(.lead)
        try await Task.sleep(for: .milliseconds(50))
        let calls = client.featureListCalls
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.featureListCalls == calls, "My First Mate refreshes nothing")
        run.cancel()
        await run.value
    }
}

@MainActor
private final class StoreTestState {
    var tokens = ["alpha": "alpha-token", "beta": "beta-token"]
    var clientsMade = 0
}
