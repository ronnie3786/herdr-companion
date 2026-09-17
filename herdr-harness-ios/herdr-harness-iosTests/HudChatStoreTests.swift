import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Saved HUD chat state", .serialized)
@MainActor
struct HudChatStoreTests {
    @Test("Catalog pagination is deduplicated and scoped to the selected machine")
    func catalogPagination() async throws {
        let transport = HudChatFakeTransport()
        transport.catalogPages["work||0"] = HudChatCatalog(
            chats: [summary(id: "agr_same", latest: "agr_work_1")],
            nextOffset: 50
        )
        transport.catalogPages["work||50"] = HudChatCatalog(
            chats: [summary(id: "agr_same", latest: "agr_work_1"), summary(id: "agr_work_2", latest: "agr_work_2")],
            nextOffset: nil
        )
        transport.catalogPages["home||0"] = HudChatCatalog(
            chats: [summary(id: "agr_same", latest: "agr_home_1")],
            nextOffset: nil
        )
        let store = HudChatStore()

        await store.load(machineID: "work", query: "", transport: transport)
        await store.loadMore(transport: transport)
        #expect(store.chats.map(\.id) == ["agr_same", "agr_work_2"])
        #expect(store.chats.first?.scopedID(machineID: store.machineID) == "work|agr_same")

        await store.load(machineID: "home", query: "", transport: transport)
        #expect(store.machineID == "home")
        #expect(store.chats.map(\.latestRunId) == ["agr_home_1"])
        #expect(store.chats.first?.scopedID(machineID: store.machineID) == "home|agr_same")
    }

    @Test("Opening a chat retrieves every history page in server order")
    func historyPagination() async throws {
        let transport = HudChatFakeTransport()
        let first = try run(id: "agr_root", status: .completed, prompt: "One", response: "First")
        let second = try run(id: "agr_second", status: .completed, prompt: "Two", response: "Second", root: "agr_root")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [first], rootRunId: "agr_root", latestRunId: "agr_second", promotedPaneId: nil, nextOffset: 50
        )
        transport.histories["agr_root|50"] = HudChatHistory(
            turns: [second], rootRunId: "agr_root", latestRunId: "agr_second", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)

        await store.open(summary(id: "agr_root", latest: "agr_second", turns: 2), transport: transport)

        #expect(store.turns.map(\.id) == ["agr_root", "agr_second"])
        #expect(store.latestRunID == "agr_second")
        #expect(transport.historyRequests == ["work|agr_root|0", "work|agr_root|50"])
    }

    @Test("New chats preserve drafts on capability errors and pass custom cwd only when supported")
    func createAndCustomFolderGuard() async throws {
        let transport = HudChatFakeTransport()
        transport.capabilities = HudChatCapabilities(profiles: ["hud-chat-v1"], hudChatWorkingDirectory: false)
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        store.beginNewChat()
        store.usesCustomWorkingDirectory = true
        store.newWorkingDirectory = "/srv/synthetic-project"
        store.draft = "Inspect the project"

        await store.submit(model: nil, thinkingLevel: "high", transport: transport)

        #expect(transport.starts.isEmpty)
        #expect(store.draft == "Inspect the project")
        #expect(store.errorMessage?.contains("server") == true)

        transport.capabilities = HudChatCapabilities(profiles: ["hud-chat-v1"], hudChatWorkingDirectory: true)
        await store.showAndReloadForTest(machineID: "work", transport: transport)
        store.beginNewChat()
        store.usesCustomWorkingDirectory = true
        store.newWorkingDirectory = "/srv/synthetic-project"
        store.draft = "Inspect the project"
        transport.startHandler = { request in
            try run(id: "agr_created", status: .queued, prompt: request.prompt, response: nil, cwd: request.cwd)
        }

        await store.submit(model: "provider/model", thinkingLevel: "high", transport: transport)

        #expect(transport.starts.count == 1)
        #expect(transport.starts.first?.cwd == "/srv/synthetic-project")
        #expect(transport.starts.first?.continueFromRunID == nil)
        #expect(store.rootRunID == "agr_created")
        #expect(store.draft.isEmpty)
    }

    @Test("Continuation refreshes first, uses the authoritative latest id, and never sends cwd")
    func continuation() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Done")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        transport.startHandler = { request in
            try run(id: "agr_reply", status: .queued, prompt: request.prompt, response: nil, root: "agr_root")
        }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        store.draft = "Follow up"
        transport.historyRequests.removeAll()

        await store.submit(model: nil, thinkingLevel: "max", transport: transport)

        #expect(transport.historyRequests == ["work|agr_root|0"])
        #expect(transport.starts.first?.continueFromRunID == "agr_root")
        #expect(transport.starts.first?.cwd == nil)
        #expect(store.turns.map(\.id) == ["agr_root", "agr_reply"])
        #expect(store.draft.isEmpty)
    }

    @Test("A newer authoritative turn blocks append without resubmission and keeps the draft")
    func conflictRefresh() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Done")
        let newer = try run(id: "agr_newer", status: .completed, prompt: "Remote", response: "Updated", root: "agr_root")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        store.draft = "My unsent reply"
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root, newer], rootRunId: "agr_root", latestRunId: "agr_newer", promotedPaneId: nil, nextOffset: nil
        )

        await store.submit(model: nil, thinkingLevel: "max", transport: transport)

        #expect(transport.starts.isEmpty)
        #expect(store.latestRunID == "agr_newer")
        #expect(store.turns.map(\.id) == ["agr_root", "agr_newer"])
        #expect(store.draft == "My unsent reply")
        #expect(store.errorMessage?.contains("newer reply") == true)
    }

    @Test("A failed preflight refresh preserves the draft and does not append")
    func failedPreflight() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Done")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        store.draft = "Do not lose this"
        transport.histories.removeAll()

        await store.submit(model: nil, thinkingLevel: "high", transport: transport)

        #expect(transport.starts.isEmpty)
        #expect(store.draft == "Do not lose this")
        #expect(store.errorMessage != nil)
    }

    @Test("Server conflicts refresh once without automatic retry")
    func serverConflict() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Done")
        let newer = try run(id: "agr_remote", status: .completed, prompt: "Remote", response: "Done", root: "agr_root")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        store.draft = "Keep this"
        transport.startHandler = { _ in
            transport.histories["agr_root|0"] = HudChatHistory(
                turns: [root, newer], rootRunId: "agr_root", latestRunId: "agr_remote", promotedPaneId: nil, nextOffset: nil
            )
            throw APIError.server(status: 409, message: "stale")
        }

        await store.submit(model: nil, thinkingLevel: "high", transport: transport)

        #expect(transport.starts.count == 1)
        #expect(store.latestRunID == "agr_remote")
        #expect(store.draft == "Keep this")
        #expect(store.errorMessage?.contains("another device") == true)
    }

    @Test("Stop targets the refreshed latest active run; leaving never stops or deletes")
    func stopAndNonDestructiveNavigation() async throws {
        let transport = HudChatFakeTransport()
        let active = try run(id: "agr_active", status: .running, prompt: "Work", response: nil)
        transport.histories["agr_active|0"] = HudChatHistory(
            turns: [active], rootRunId: "agr_active", latestRunId: "agr_active", promotedPaneId: nil, nextOffset: nil
        )
        transport.stopHandler = { _, id in
            try run(id: id, status: .cancelled, prompt: "Work", response: nil)
        }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_active", latest: "agr_active", status: .running), transport: transport)

        store.showCatalog()
        #expect(transport.stops.isEmpty)
        #expect(transport.starts.isEmpty)

        await store.open(summary(id: "agr_active", latest: "agr_active", status: .running), transport: transport)
        await store.stop(transport: transport)
        #expect(transport.stops == ["work|agr_active"])
        #expect(store.latestRun?.status == .cancelled)
    }

    @Test("Cancelling foreground observation stops polling without stopping the server run")
    func observationCancellation() async throws {
        let transport = HudChatFakeTransport()
        let active = try run(id: "agr_active", status: .running, prompt: "Work", response: nil)
        let history = HudChatHistory(
            turns: [active], rootRunId: "agr_active", latestRunId: "agr_active", promotedPaneId: nil, nextOffset: nil
        )
        transport.histories["agr_active|0"] = history
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_active", latest: "agr_active", status: .running), transport: transport)
        let gate = HistoryGate()
        transport.historyHandler = { _, _, _ in await gate.wait() }

        let observation = Task { await store.observe(transport: transport) }
        while !gate.isWaiting { await Task.yield() }
        observation.cancel()
        gate.resume(history)
        await observation.value

        #expect(!store.isObserving)
        #expect(transport.stops.isEmpty)
    }

    @Test("Accepted continuation keeps foreground observation polling external updates")
    func continuationPreservesForegroundObservation() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Initial")
        let queued = try run(
            id: "agr_reply",
            status: .queued,
            prompt: "Follow up",
            response: nil,
            root: "agr_root"
        )
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        transport.startHandler = { _ in queued }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        let waitGate = ObservationWaitSequenceGate()
        let observation = Task {
            await store.observe(transport: transport) {
                try await waitGate.wait()
            }
        }
        while waitGate.waitingCount < 1 { await Task.yield() }
        store.draft = "Follow up"

        await store.submit(model: nil, thinkingLevel: "high", transport: transport)

        #expect(store.isObserving)
        #expect(store.latestRunID == "agr_reply")
        let completed = try run(
            id: "agr_reply",
            status: .completed,
            prompt: "Follow up",
            response: "External completion",
            root: "agr_root"
        )
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root, completed],
            rootRunId: "agr_root",
            latestRunId: "agr_reply",
            promotedPaneId: nil,
            nextOffset: nil
        )
        waitGate.resume(at: 0)
        while waitGate.waitingCount < 2 { await Task.yield() }

        #expect(store.latestRun?.status == .completed)
        #expect(store.latestRun?.response == "External completion")
        observation.cancel()
        waitGate.resume(at: 1)
        await observation.value
        #expect(!store.isObserving)
    }

    @Test("Accepted stop keeps foreground observation polling external updates")
    func stopPreservesForegroundObservation() async throws {
        let transport = HudChatFakeTransport()
        let active = try run(id: "agr_active", status: .running, prompt: "Work", response: nil)
        transport.histories["agr_active|0"] = HudChatHistory(
            turns: [active], rootRunId: "agr_active", latestRunId: "agr_active", promotedPaneId: nil, nextOffset: nil
        )
        transport.stopHandler = { _, id in
            try run(id: id, status: .cancelled, prompt: "Work", response: nil)
        }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_active", latest: "agr_active", status: .running), transport: transport)
        let waitGate = ObservationWaitSequenceGate()
        let observation = Task {
            await store.observe(transport: transport) {
                try await waitGate.wait()
            }
        }
        while waitGate.waitingCount < 1 { await Task.yield() }

        await store.stop(transport: transport)

        #expect(store.isObserving)
        #expect(store.latestRun?.status == .cancelled)
        let externallyUpdated = try run(
            id: "agr_active",
            status: .cancelled,
            prompt: "Work",
            response: "External partial result"
        )
        transport.histories["agr_active|0"] = HudChatHistory(
            turns: [externallyUpdated],
            rootRunId: "agr_active",
            latestRunId: "agr_active",
            promotedPaneId: nil,
            nextOffset: nil
        )
        waitGate.resume(at: 0)
        while waitGate.waitingCount < 2 { await Task.yield() }

        #expect(store.latestRun?.response == "External partial result")
        observation.cancel()
        waitGate.resume(at: 1)
        await observation.value
        #expect(!store.isObserving)
    }

    @Test("A suspended failed send cannot overwrite another machine's draft")
    func failedSendOwnsItsCapturedDraft() async throws {
        let transport = HudChatFakeTransport()
        let gate = RunGate()
        transport.startHandler = { _ in try await gate.wait() }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        store.beginNewChat()
        store.draft = "Original work draft"

        let submission = Task { await store.submit(model: nil, thinkingLevel: "high", transport: transport) }
        while !gate.isWaiting { await Task.yield() }

        await store.load(machineID: "home", query: "", transport: transport)
        store.beginNewChat()
        store.draft = "New home draft"
        gate.fail(APIError.server(status: 503, message: "synthetic failure"))
        await submission.value

        #expect(store.machineID == "home")
        #expect(store.draft == "New home draft")
        await store.load(machineID: "work", query: "", transport: transport)
        store.beginNewChat()
        #expect(store.draft == "Original work draft")
    }

    @Test("A suspended send accepted after navigation remains in the catalog cache")
    func acceptedSendAfterNavigationIsDiscoverable() async throws {
        let transport = HudChatFakeTransport()
        let gate = RunGate()
        transport.startHandler = { _ in try await gate.wait() }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        store.beginNewChat()
        store.draft = "Create a saved chat"

        let submission = Task { await store.submit(model: nil, thinkingLevel: "high", transport: transport) }
        while !gate.isWaiting { await Task.yield() }
        store.showCatalog()
        gate.succeed(try run(id: "agr_created", status: .queued, prompt: "Create a saved chat", response: nil))
        await submission.value

        #expect(!store.isShowingConversation)
        #expect(store.chats.first?.id == "agr_created")
        #expect(store.draft.isEmpty)
        await store.open(store.chats[0], transport: transport)
        #expect(store.turns.map(\.id) == ["agr_created"])
    }

    @Test("An accepted suspended send keeps later edits and caches the accepted thread")
    func acceptedSendKeepsLaterEdits() async throws {
        let transport = HudChatFakeTransport()
        let gate = RunGate()
        transport.startHandler = { _ in try await gate.wait() }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        store.beginNewChat()
        store.draft = "Original prompt"

        let submission = Task { await store.submit(model: nil, thinkingLevel: "high", transport: transport) }
        while !gate.isWaiting { await Task.yield() }
        store.draft = "A later follow-up"
        gate.succeed(try run(id: "agr_created", status: .queued, prompt: "Original prompt", response: nil))
        await submission.value

        #expect(store.rootRunID == "agr_created")
        #expect(store.draft == "A later follow-up")
        store.showCatalog()
        #expect(store.chats.first?.id == "agr_created")
        await store.open(store.chats[0], transport: transport)
        #expect(store.turns.map(\.id) == ["agr_created"])
        #expect(store.draft == "A later follow-up")
    }

    @Test("Only the newest same-context history response can update the transcript")
    func orderedHistoryOwnership() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Initial")
        let newer = try run(id: "agr_newer", status: .completed, prompt: "Remote", response: "New", root: "agr_root")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        let gate = HistorySequenceGate()
        transport.historyHandler = { _, _, _ in await gate.wait() }

        let olderRequest = Task { await store.refreshConversation(transport: transport) }
        while gate.waitingCount < 1 { await Task.yield() }
        let newerRequest = Task { await store.refreshConversation(transport: transport) }
        while gate.waitingCount < 2 { await Task.yield() }

        gate.resume(
            at: 1,
            with: HudChatHistory(
                turns: [root, newer], rootRunId: "agr_root", latestRunId: "agr_newer", promotedPaneId: nil, nextOffset: nil
            )
        )
        _ = await newerRequest.value
        gate.resume(
            at: 0,
            with: HudChatHistory(
                turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
            )
        )
        _ = await olderRequest.value

        #expect(store.latestRunID == "agr_newer")
        #expect(store.turns.map(\.id) == ["agr_root", "agr_newer"])
        #expect(!store.isLoadingHistory)
    }

    @Test("A submit preflight supersedes a suspended passive history read")
    func preflightOwnsAuthoritativeHistory() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Initial")
        let reply = try run(id: "agr_reply", status: .queued, prompt: "Follow up", response: nil, root: "agr_root")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        transport.startHandler = { _ in reply }
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        store.draft = "Follow up"
        let gate = HistorySequenceGate()
        transport.historyHandler = { _, _, _ in await gate.wait() }

        let passive = Task { await store.refreshConversation(transport: transport) }
        while gate.waitingCount < 1 { await Task.yield() }
        let submission = Task { await store.submit(model: nil, thinkingLevel: "high", transport: transport) }
        while gate.waitingCount < 2 { await Task.yield() }
        gate.resume(
            at: 1,
            with: HudChatHistory(
                turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
            )
        )
        await submission.value
        gate.resume(
            at: 0,
            with: HudChatHistory(
                turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
            )
        )
        _ = await passive.value

        #expect(transport.starts.count == 1)
        #expect(store.latestRunID == "agr_reply")
        #expect(store.turns.map(\.id) == ["agr_root", "agr_reply"])

        let reopenGate = HistoryGate()
        transport.historyHandler = { _, _, _ in await reopenGate.wait() }
        store.showCatalog()
        let reopening = Task {
            await store.open(summary(id: "agr_root", latest: "agr_reply", turns: 2), transport: transport)
        }
        while !reopenGate.isWaiting { await Task.yield() }
        #expect(store.turns.map(\.id) == ["agr_root", "agr_reply"])
        reopenGate.resume(
            HudChatHistory(
                turns: [root, reply],
                rootRunId: "agr_root",
                latestRunId: "agr_reply",
                promotedPaneId: nil,
                nextOffset: nil
            )
        )
        await reopening.value
    }

    @Test("A stale history defer cannot clear a newer request's loading state")
    func historyLoadingOwnershipAcrossNavigation() async throws {
        let transport = HudChatFakeTransport()
        let root = try run(id: "agr_root", status: .completed, prompt: "One", response: "Initial")
        transport.histories["agr_root|0"] = HudChatHistory(
            turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport)
        let gate = HistorySequenceGate()
        transport.historyHandler = { _, _, _ in await gate.wait() }

        let first = Task { await store.refreshConversation(transport: transport) }
        while gate.waitingCount < 1 { await Task.yield() }
        #expect(store.isLoadingHistory)
        store.showCatalog()
        #expect(!store.isLoadingHistory)
        let second = Task { await store.open(summary(id: "agr_root", latest: "agr_root"), transport: transport) }
        while gate.waitingCount < 2 { await Task.yield() }
        #expect(store.isLoadingHistory)

        gate.resume(
            at: 0,
            with: HudChatHistory(
                turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
            )
        )
        _ = await first.value
        #expect(store.isLoadingHistory)
        gate.resume(
            at: 1,
            with: HudChatHistory(
                turns: [root], rootRunId: "agr_root", latestRunId: "agr_root", promotedPaneId: nil, nextOffset: nil
            )
        )
        await second.value
        #expect(!store.isLoadingHistory)
    }

    @Test("Foreground catalog sync updates the first page without discarding loaded pages")
    func foregroundCatalogSyncPreservesPagination() async throws {
        let transport = HudChatFakeTransport()
        transport.catalogPages["work||0"] = HudChatCatalog(
            chats: [summary(id: "agr_same", latest: "agr_old")],
            nextOffset: 50
        )
        transport.catalogPages["work||50"] = HudChatCatalog(
            chats: [summary(id: "agr_page_two", latest: "agr_page_two")],
            nextOffset: 100
        )
        let store = HudChatStore()
        await store.load(machineID: "work", query: "", transport: transport)
        await store.loadMore(transport: transport)
        transport.catalogHandler = { _, _, offset in
            #expect(offset == 0)
            return HudChatCatalog(
                chats: [
                    summary(id: "agr_new", latest: "agr_new", status: .running),
                    summary(id: "agr_same", latest: "agr_changed", status: .running),
                ],
                nextOffset: 50
            )
        }

        await store.syncCatalog(transport: transport)

        #expect(store.chats.map(\.id) == ["agr_new", "agr_same", "agr_page_two"])
        #expect(store.chats.first(where: { $0.id == "agr_same" })?.latestRunId == "agr_changed")
        #expect(store.nextCatalogOffset == 100)
        #expect(!store.isLoadingCatalog)
    }

    @Test("Only the newest same-context catalog response can update the list")
    func orderedCatalogOwnership() async throws {
        let transport = HudChatFakeTransport()
        let gate = CatalogSequenceGate()
        transport.catalogHandler = { _, _, _ in await gate.wait() }
        let store = HudChatStore()

        let first = Task { await store.load(machineID: "work", query: "", transport: transport) }
        while gate.waitingCount < 1 { await Task.yield() }
        let second = Task { await store.load(machineID: "work", query: "", transport: transport) }
        while gate.waitingCount < 2 { await Task.yield() }
        gate.resume(
            at: 1,
            with: HudChatCatalog(chats: [summary(id: "agr_new", latest: "agr_new")], nextOffset: nil)
        )
        await second.value
        gate.resume(
            at: 0,
            with: HudChatCatalog(chats: [summary(id: "agr_old", latest: "agr_old")], nextOffset: nil)
        )
        await first.value

        #expect(store.chats.map(\.id) == ["agr_new"])
        #expect(!store.isLoadingCatalog)
    }

    @Test("Promoted pane navigation is bound to its captured HUD context")
    func promotedPaneNavigationContext() {
        let target = HudChatsView.PromotedPaneNavigationTarget(
            machineID: "work",
            rootRunID: "agr_root",
            promotedPaneID: "pane-1"
        )

        #expect(target?.scopedPaneID == "work|pane-1")
        #expect(HudChatsView.PromotedPaneNavigationTarget(
            machineID: "work",
            rootRunID: "agr_root",
            promotedPaneID: "home|pane-1"
        ) == nil)
        #expect(target?.matches(
            isShowingConversation: true,
            machineID: "work",
            rootRunID: "agr_root",
            promotedPaneID: "pane-1"
        ) == true)
        #expect(target?.matches(
            isShowingConversation: true,
            machineID: "home",
            rootRunID: "agr_root",
            promotedPaneID: "pane-1"
        ) == false)
        #expect(target?.matches(
            isShowingConversation: true,
            machineID: "work",
            rootRunID: "agr_other",
            promotedPaneID: "pane-1"
        ) == false)
        #expect(target?.matches(
            isShowingConversation: true,
            machineID: "work",
            rootRunID: "agr_root",
            promotedPaneID: "pane-2"
        ) == false)
    }

    @Test("A late response from the old machine cannot replace the new machine catalog")
    func machineChangeRaceAndDraftPreservation() async throws {
        let transport = HudChatFakeTransport()
        let gate = CatalogGate()
        transport.catalogHandler = { machineID, _, _ in
            if machineID == "slow" { return await gate.wait() }
            return HudChatCatalog(chats: [summary(id: "agr_fast", latest: "agr_fast")], nextOffset: nil)
        }
        let store = HudChatStore()
        let slowLoad = Task { await store.load(machineID: "slow", query: "", transport: transport) }
        while !gate.isWaiting { await Task.yield() }

        await store.load(machineID: "fast", query: "", transport: transport)
        store.beginNewChat()
        store.draft = "Fast machine draft"
        gate.resume(HudChatCatalog(chats: [summary(id: "agr_slow", latest: "agr_slow")], nextOffset: nil))
        await slowLoad.value

        #expect(store.machineID == "fast")
        #expect(store.chats.map(\.id) == ["agr_fast"])
        #expect(store.draft == "Fast machine draft")

        transport.catalogHandler = { _, _, _ in HudChatCatalog(chats: [], nextOffset: nil) }
        await store.load(machineID: "other", query: "", transport: transport)
        await store.load(machineID: "fast", query: "", transport: transport)
        #expect(store.draft == "Fast machine draft")
    }
}

private extension HudChatStore {
    func showAndReloadForTest(machineID: String, transport: any HudChatTransport) async {
        showCatalog()
        await load(machineID: machineID, query: "", transport: transport)
    }
}

@MainActor
private final class CatalogGate {
    private var continuation: CheckedContinuation<HudChatCatalog, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> HudChatCatalog {
        await withCheckedContinuation { self.continuation = $0 }
    }

    func resume(_ catalog: HudChatCatalog) {
        continuation?.resume(returning: catalog)
        continuation = nil
    }
}

@MainActor
private final class HistoryGate {
    private var continuation: CheckedContinuation<HudChatHistory, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> HudChatHistory {
        await withCheckedContinuation { self.continuation = $0 }
    }

    func resume(_ history: HudChatHistory) {
        continuation?.resume(returning: history)
        continuation = nil
    }
}

@MainActor
private final class ObservationWaitSequenceGate {
    private var continuations: [CheckedContinuation<Void, any Error>?] = []
    var waitingCount: Int { continuations.count }

    func wait() async throws {
        try await withCheckedThrowingContinuation {
            continuations.append($0)
        }
    }

    func resume(at index: Int) {
        continuations[index]?.resume(returning: ())
        continuations[index] = nil
    }
}

@MainActor
private final class RunGate {
    private var continuation: CheckedContinuation<HeadlessAgentRun, any Error>?
    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> HeadlessAgentRun {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func succeed(_ run: HeadlessAgentRun) {
        continuation?.resume(returning: run)
        continuation = nil
    }

    func fail(_ error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class HistorySequenceGate {
    private var continuations: [CheckedContinuation<HudChatHistory, Never>?] = []
    var waitingCount: Int { continuations.count }

    func wait() async -> HudChatHistory {
        await withCheckedContinuation {
            continuations.append($0)
        }
    }

    func resume(at index: Int, with history: HudChatHistory) {
        continuations[index]?.resume(returning: history)
        continuations[index] = nil
    }
}

@MainActor
private final class CatalogSequenceGate {
    private var continuations: [CheckedContinuation<HudChatCatalog, Never>?] = []
    var waitingCount: Int { continuations.count }

    func wait() async -> HudChatCatalog {
        await withCheckedContinuation {
            continuations.append($0)
        }
    }

    func resume(at index: Int, with catalog: HudChatCatalog) {
        continuations[index]?.resume(returning: catalog)
        continuations[index] = nil
    }
}

@MainActor
private final class HudChatFakeTransport: HudChatTransport {
    struct Start: Equatable, Sendable {
        let machineID: String
        let prompt: String
        let cwd: String?
        let model: String?
        let thinkingLevel: String?
        let continueFromRunID: String?
    }

    var capabilities = HudChatCapabilities(profiles: ["hud-chat-v1"], hudChatWorkingDirectory: true)
    var catalogPages: [String: HudChatCatalog] = [:]
    var histories: [String: HudChatHistory] = [:]
    var historyRequests: [String] = []
    var starts: [Start] = []
    var stops: [String] = []
    var catalogHandler: (@MainActor (String, String, Int) async throws -> HudChatCatalog)?
    var historyHandler: (@MainActor (String, String, Int) async throws -> HudChatHistory)?
    var startHandler: (@MainActor (Start) async throws -> HeadlessAgentRun)?
    var stopHandler: (@MainActor (String, String) async throws -> HeadlessAgentRun)?

    func fetchHudChatCapabilities(machineID: String) async throws -> HudChatCapabilities {
        capabilities
    }

    func fetchHudChatCatalog(machineID: String, query: String, offset: Int) async throws -> HudChatCatalog {
        if let catalogHandler { return try await catalogHandler(machineID, query, offset) }
        return catalogPages["\(machineID)|\(query)|\(offset)"] ?? HudChatCatalog(chats: [], nextOffset: nil)
    }

    func fetchHudChatHistory(machineID: String, id: String, offset: Int) async throws -> HudChatHistory {
        historyRequests.append("\(machineID)|\(id)|\(offset)")
        if let historyHandler { return try await historyHandler(machineID, id, offset) }
        guard let history = histories["\(id)|\(offset)"] else { throw APIError.invalidResponse }
        return history
    }

    func startHudChat(
        machineID: String,
        prompt: String,
        cwd: String?,
        model: String?,
        thinkingLevel: String?,
        continueFromRunId: String?
    ) async throws -> HeadlessAgentRun {
        let request = Start(
            machineID: machineID,
            prompt: prompt,
            cwd: cwd,
            model: model,
            thinkingLevel: thinkingLevel,
            continueFromRunID: continueFromRunId
        )
        starts.append(request)
        guard let startHandler else { throw APIError.invalidResponse }
        return try await startHandler(request)
    }

    func stopHudChat(machineID: String, runID: String) async throws -> HeadlessAgentRun {
        stops.append("\(machineID)|\(runID)")
        guard let stopHandler else { throw APIError.invalidResponse }
        return try await stopHandler(machineID, runID)
    }

    func fetchHudChatModels(machineID: String) async throws -> AgentModelCatalogResponse {
        AgentModelCatalogResponse(ok: true, models: [], defaultModel: nil)
    }
}

private func summary(
    id: String,
    latest: String,
    turns: Int = 1,
    status: HeadlessAgentRunStatus = .completed
) -> HudChatSummary {
    HudChatSummary(
        id: id,
        title: "Synthetic chat",
        updatedAt: "2026-09-17T00:00:00Z",
        latestRunId: latest,
        turnCount: turns,
        status: status,
        sessionId: "synthetic-session",
        promotedPaneId: nil,
        cwd: "/srv/example"
    )
}

private func run(
    id: String,
    status: HeadlessAgentRunStatus,
    prompt: String,
    response: String?,
    root: String? = nil,
    cwd: String? = "/srv/example"
) throws -> HeadlessAgentRun {
    var object: [String: Any] = [
        "id": id,
        "status": status.rawValue,
        "mode": "act",
        "prompt": prompt,
        "createdAt": "2026-09-17T00:00:00Z",
        "threadRootRunId": root ?? id,
    ]
    object["response"] = response ?? NSNull()
    object["error"] = NSNull()
    object["cwd"] = cwd ?? NSNull()
    return try JSONDecoder().decode(HeadlessAgentRun.self, from: JSONSerialization.data(withJSONObject: object))
}
