import CryptoKit
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief length integration", .serialized)
@MainActor
struct ResponseBriefLengthIntegrationTests {
    @Test("Minimal is the default and reaches the server as an explicit selection")
    func minimalDefaultReachesServer() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-minimal")
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        #expect(coordinator.length == .minimal)
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.responseBriefLength == .minimal)
        #expect(request.prompt == ResponseBriefRequestBuilder.lengthPrompt)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(object["responseBriefLength"] as? String == "minimal")

        let record = try #require(coordinator.briefs(for: source.chat).first)
        #expect(record.responseBriefLength == .minimal)
        #expect(record.responseBriefLengthPolicyVersion == ResponseBriefLength.policyVersion)
        #expect(record.briefConformsToCapturedPolicy)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
    }

    @Test("Length changes regenerate the selected source with distinct fresh request identities")
    func lengthChangesRegenerateSelectedSource() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-change")
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)

        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 2)
        #expect(requests[1].responseBriefLength == .medium)
        #expect(requests[1].clientRequestId != requests[0].clientRequestId)

        // Selecting the current value is a no-op.
        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 2)

        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 3)
        #expect(requests[2].responseBriefLength == .long)

        // Returning to a formerly used preset still creates a deliberate fresh request.
        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 4)
        #expect(requests[3].responseBriefLength == .medium)
        #expect(Set(requests.map(\.clientRequestId)).count == 4)
        #expect(coordinator.length == .medium)
        #expect(coordinator.briefs(for: source.chat).count == 4)

        let stored = try await fixture.persistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
        #expect(Set(stored.records.compactMap(\.responseBriefLength)) == [.minimal, .medium, .long])
    }

    @Test("Changing length targets the pinned prior source instead of the latest")
    func lengthChangeTargetsPinnedPriorSource() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let older = fixture.source(responseID: "entry-old")
        let latest = fixture.source(
            responseID: "entry-new",
            text: older.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(older.chat))
        await coordinator.observeSources([older, latest], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.map(\.context.source.instanceId) == [latest.responseID])

        await coordinator.changeLength(
            .long,
            chat: older.chat,
            selectedSource: older,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 2)
        #expect(requests[1].context.source.instanceId == older.responseID)
        #expect(requests[1].responseBriefLength == .long)
        let records = coordinator.briefs(for: older.chat)
        #expect(Set(records.map(\.source.responseID)) == [older.responseID, latest.responseID])
        #expect(records.first(where: { $0.source.responseID == older.responseID })?.responseBriefLength == .long)
        #expect(records.first(where: { $0.source.responseID == latest.responseID })?.responseBriefLength == .minimal)
    }

    @Test("Rapid changes coalesce to the latest selection while accepted work owns the chat")
    func rapidChangesCoalesceWhileBusy() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-rapid")
        var requests: [AssistantRequest] = []
        var release: CheckedContinuation<Void, Never>?
        var didStart: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { didStart = $0 }
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                if requests.count == 1 {
                    didStart?.yield()
                    await withCheckedContinuation { release = $0 }
                }
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: transport)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        #expect(requests.count == 1)

        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        #expect(requests.count == 1)
        let coalesced = try await fixture.persistence.snapshot()
        #expect(coalesced.pendingRegenerations[source.chat.id]?.length == .medium)
        #expect(coalesced.pendingRegenerations.count == 1)

        release?.resume()
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 2)
        #expect(requests[1].responseBriefLength == .medium)
        #expect(requests[1].clientRequestId != requests[0].clientRequestId)
        #expect(coordinator.briefs(for: source.chat).count == 2)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
    }

    @Test("A pending replacement resumes once after relaunch, behind accepted ownership")
    func pendingReplacementResumesAfterRelaunch() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let source = fixture.source(responseID: "entry-relaunch")
        let accepted = fixture.source(
            responseID: "entry-accepted",
            text: source.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let acceptedRequest = try ResponseBriefRequestBuilder.request(
            for: accepted,
            model: "provider/brief-model",
            thinkingLevel: nil
        )
        try await fixture.persistence.saveReceipt(.init(
            id: fixture.legacyGenerationID(for: accepted, model: "provider/brief-model", thinkingLevel: nil),
            source: accepted,
            request: acceptedRequest,
            runID: "agr_synthetic0001",
            createdAt: .now
        ))
        // A predecessor process persisted the coalesced replacement intent.
        try await fixture.persistence.savePendingRegeneration(.init(
            chatID: source.chat.id,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        ))

        var starts: [AssistantRequest] = []
        var fetches = 0
        let relaunchedPersistence = ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: relaunchedPersistence
        )
        relaunched.selectModel("provider/brief-model")
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        let transport = fixture.transport(
            start: { request in
                starts.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in
                fetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )

        await relaunched.observe(source, transport: transport)
        await relaunched.waitForIdleForTesting()

        #expect(fetches == 1)
        #expect(starts.count == 1)
        #expect(starts.first?.context.source.instanceId == source.responseID)
        #expect(starts.first?.responseBriefLength == .long)
        #expect(relaunched.briefs(for: source.chat).count == 2)
        let stored = try await relaunchedPersistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
        #expect(stored.receipts.isEmpty)
    }

    @Test("An uncertain submission keeps its accepted receipt and reconciles without a fresh capability check")
    func uncertainSubmissionReconcilesAcceptedReceipt() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-uncertain")
        let workingTransport = fixture.transport(
            start: { _ in fixture.run(status: .completed, response: fixture.validJSON) },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: workingTransport)
        await coordinator.waitForIdleForTesting()

        var startAttempts = 0
        let failingTransport = fixture.transport(
            start: { _ in
                startAttempts += 1
                throw APIError.invalidResponse
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: failingTransport
        )
        await coordinator.waitForIdleForTesting()

        #expect(startAttempts == 1)
        let interrupted = try await fixture.persistence.snapshot()
        let receipt = try #require(interrupted.receipts.first)
        #expect(receipt.status == .needsExplicitRetry)
        #expect(receipt.request.responseBriefLength == .medium)
        #expect(interrupted.pendingRegenerations.isEmpty)

        // Relaunch against an old server: the saved receipt keeps reconciling
        // without a fresh length-capability check. The interrupted POST never
        // returned a run ID, so retry replays the exact captured request (the
        // server deduplicates by clientRequestId) and then polls that run to a
        // terminal reconciled state.
        let relaunchedPersistence = ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: relaunchedPersistence
        )
        relaunched.selectModel("provider/brief-model")
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        var replayedRequests: [AssistantRequest] = []
        var fetches = 0
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                replayedRequests.append(request)
                return fixture.run(status: .queued, response: nil)
            },
            fetch: { _ in
                fetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )
        await relaunched.retry(source, transport: oldTransport)
        await relaunched.waitForIdleForTesting()

        #expect(replayedRequests.count == 1)
        let replay = try #require(replayedRequests.first)
        #expect(replay.clientRequestId == receipt.request.clientRequestId)
        #expect(replay.prompt == receipt.request.prompt)
        #expect(replay.model == receipt.request.model)
        #expect(replay.thinkingLevel == receipt.request.thinkingLevel)
        #expect(replay.responseBriefLength == .medium)
        #expect(replay.context == receipt.request.context)
        #expect(fetches == 1)
        #expect(relaunched.state(for: source.chat).phase == .idle)
        let record = try #require(
            relaunched.briefs(for: source.chat).first { $0.responseBriefLength == .medium }
        )
        #expect(record.briefConformsToCapturedPolicy)
        let stored = try await relaunchedPersistence.snapshot()
        #expect(stored.receipts.isEmpty)
    }

    @Test("Disabling a chat drops its unsubmitted replacement intent")
    func disableDropsPendingReplacementIntent() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let source = fixture.source(responseID: "entry-disable")
        let accepted = fixture.source(
            responseID: "entry-accepted-disable",
            text: source.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let acceptedRequest = try ResponseBriefRequestBuilder.request(
            for: accepted,
            model: "provider/brief-model",
            thinkingLevel: nil
        )
        try await fixture.persistence.saveReceipt(.init(
            id: fixture.legacyGenerationID(for: accepted, model: "provider/brief-model", thinkingLevel: nil),
            source: accepted,
            request: acceptedRequest,
            runID: "agr_synthetic0001",
            createdAt: .now,
            status: .needsExplicitRetry
        ))
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        #expect(coordinator.enable(source.chat))
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.isEmpty)

        await coordinator.disable(source.chat, transport: transport)
        #expect(coordinator.length == .long)
        #expect(requests.isEmpty)

        // The durable intent is removed so a later relaunch cannot resume it.
        var intentRemoved = false
        for _ in 0..<200 {
            if (try? await fixture.persistence.snapshot().pendingRegenerations[source.chat.id]) == nil {
                intentRemoved = true
                break
            }
            await Task.yield()
        }
        #expect(intentRemoved)
    }

    @Test("The app-wide preference reaches another chat and a different model configuration")
    func preferenceAppliesAcrossChatsAndModels() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let firstChat = fixture.source(responseID: "entry-machine-one")
        let secondChat = fixture.source(
            responseID: "entry-machine-two",
            chat: .init(
                machineID: "synthetic-other-machine",
                paneID: "w2:p1",
                sessionID: "synthetic-other-session"
            )
        )
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(firstChat.chat))
        #expect(coordinator.enable(secondChat.chat))
        await coordinator.observe(firstChat, transport: transport)
        await coordinator.observe(secondChat, transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.responseBriefLength == .minimal })

        await coordinator.changeLength(
            .long,
            chat: firstChat.chat,
            selectedSource: firstChat,
            transport: transport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 3)
        #expect(requests[2].responseBriefLength == .long)
        #expect(requests[2].context.source.instanceId == firstChat.responseID)
        #expect(coordinator.briefs(for: secondChat.chat).count == 1)

        // A later answer in the other chat adopts the stored preference without
        // bulk-regenerating the chat's earlier brief.
        coordinator.selectModel("provider/other-model")
        let later = fixture.source(
            responseID: "entry-machine-two-later",
            chat: secondChat.chat,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_500),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_400)
        )
        await coordinator.observeSources([secondChat, later], transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 4)
        #expect(requests[3].context.source.instanceId == later.responseID)
        #expect(requests[3].responseBriefLength == .long)
        #expect(requests[3].model == "provider/other-model")
        #expect(coordinator.briefs(for: secondChat.chat).count == 2)
        #expect(requests.filter { $0.context.source.instanceId == secondChat.responseID }.count == 1)
    }

    @Test("A replacement superseded during preflight never creates a paid submission")
    func supersededPreflightReplacementDoesNotSubmit() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-preflight")
        var requests: [AssistantRequest] = []
        var capabilitiesContinuation: CheckedContinuation<Void, Never>?
        var capabilitiesStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { capabilitiesStarted = $0 }
        let transport = ResponseBriefTransport(
            capabilities: { _ in
                capabilitiesStarted?.yield()
                await withCheckedContinuation { capabilitiesContinuation = $0 }
                return fixture.capabilities()
            },
            models: { _ in
                AgentModelCatalogResponse(
                    ok: true,
                    models: [fixture.briefModel, fixture.otherModel],
                    defaultModel: nil
                )
            },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _, _ in fixture.run(status: .completed, response: fixture.validJSON) },
            cancel: { _, _ in fixture.run(status: .cancelled, response: nil, error: "cancelled") }
        )
        #expect(coordinator.enable(source.chat))

        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        var iterator = started.makeAsyncIterator()
        // Medium is suspended in capability preflight and has not submitted.
        _ = await iterator.next()
        #expect(requests.isEmpty)

        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: transport
        )
        #expect(requests.isEmpty)
        let superseded = try await fixture.persistence.snapshot()
        #expect(superseded.pendingRegenerations[source.chat.id]?.length == .long)

        capabilitiesContinuation?.resume()
        await coordinator.waitForIdleForTesting()

        // Only the still-current selection ever reaches the paid endpoint.
        #expect(requests.map(\.responseBriefLength) == [.long])
        #expect(coordinator.briefs(for: source.chat).count == 1)
        let record = try #require(coordinator.briefs(for: source.chat).first)
        #expect(record.responseBriefLength == .long)
        #expect(record.briefConformsToCapturedPolicy)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
        #expect(stored.receipts.isEmpty)
    }

    @Test("A newer selection awaiting persistence supersedes an older replacement finishing preflight")
    func newerSelectionAwaitingPersistenceSupersedesOlderPreflight() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-intent-race")
        var requests: [AssistantRequest] = []

        // Medium's first capability preflight suspends so Long can be selected
        // while Medium is still unowned.
        var capabilitiesContinuation: CheckedContinuation<Void, Never>?
        var capabilitiesStarted: AsyncStream<Void>.Continuation?
        let preflightStarted = AsyncStream<Void> { capabilitiesStarted = $0 }

        // Long's intent write then suspends at the persistence barrier, so
        // Medium resumes while the newer selection is durable but not yet
        // published.
        var barrierCalls = 0
        var releaseLong: CheckedContinuation<Void, Never>?
        var longBarrierStarted: AsyncStream<Void>.Continuation?
        let intentHeld = AsyncStream<Void> { longBarrierStarted = $0 }

        let transport = ResponseBriefTransport(
            capabilities: { _ in
                capabilitiesStarted?.yield()
                await withCheckedContinuation { capabilitiesContinuation = $0 }
                return fixture.capabilities()
            },
            models: { _ in
                AgentModelCatalogResponse(
                    ok: true,
                    models: [fixture.briefModel, fixture.otherModel],
                    defaultModel: nil
                )
            },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _, _ in fixture.run(status: .completed, response: fixture.validJSON) },
            cancel: { _, _ in fixture.run(status: .cancelled, response: nil, error: "cancelled") }
        )
        #expect(coordinator.enable(source.chat))
        coordinator.intentPersistenceBarrier = {
            barrierCalls += 1
            guard barrierCalls >= 2 else { return }
            longBarrierStarted?.yield()
            await withCheckedContinuation { releaseLong = $0 }
        }

        let mediumChange = Task { @MainActor in
            await coordinator.changeLength(
                .medium,
                chat: source.chat,
                selectedSource: source,
                transport: transport
            )
        }
        var preflightIterator = preflightStarted.makeAsyncIterator()
        _ = await preflightIterator.next()
        #expect(requests.isEmpty)

        let longChange = Task { @MainActor in
            await coordinator.changeLength(
                .long,
                chat: source.chat,
                selectedSource: source,
                transport: transport
            )
        }
        var heldIterator = intentHeld.makeAsyncIterator()
        _ = await heldIterator.next()

        // Medium revalidates after preflight while Long is suspended before
        // its own durable write. The captured Medium revision is already
        // superseded even though the stored intent is still Medium's.
        capabilitiesContinuation?.resume()
        await mediumChange.value
        await coordinator.waitForIdleForTesting()
        #expect(requests.isEmpty)
        let held = try await fixture.persistence.snapshot()
        #expect(held.pendingRegenerations[source.chat.id]?.length == .medium)

        releaseLong?.resume()
        await longChange.value
        coordinator.intentPersistenceBarrier = nil
        await coordinator.waitForIdleForTesting()

        // Only the newest selection reaches the paid endpoint.
        #expect(requests.map(\.responseBriefLength) == [.long])
        #expect(coordinator.briefs(for: source.chat).count == 1)
        let record = try #require(coordinator.briefs(for: source.chat).first)
        #expect(record.responseBriefLength == .long)
        #expect(record.briefConformsToCapturedPolicy)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.pendingRegenerations.isEmpty)
        #expect(stored.receipts.isEmpty)
    }

    @Test("A length change keeps a transport-uncertain receipt actionable and retryable after relaunch")
    func relaunchPresentsUncertainReceiptBeforeReplacement() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let uncertain = fixture.source(responseID: "entry-uncertain-ui")
        let latest = fixture.source(
            responseID: "entry-uncertain-ui-latest",
            text: uncertain.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let request = try ResponseBriefRequestBuilder.request(
            for: uncertain,
            model: "provider/brief-model",
            thinkingLevel: nil,
            clientRequestID: "uncertain-ui-request",
            length: .medium
        )
        try await fixture.persistence.saveReceipt(.init(
            id: "uncertain-ui-receipt",
            source: uncertain,
            request: request,
            runID: nil,
            createdAt: .now,
            status: .needsExplicitRetry
        ))

        let relaunchedPersistence = ResponseBriefPersistence(
            url: fixture.folder.appending(path: "cache.json")
        )
        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: relaunchedPersistence
        )
        relaunched.selectModel("provider/brief-model")
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(uncertain.chat))
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { submitted in
                requests.append(submitted)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        // A length change while an uncertain receipt owns the chat must not
        // hide that ownership behind an idle state or lose the new selection.
        await relaunched.changeLength(
            .long,
            chat: uncertain.chat,
            selectedSource: latest,
            transport: transport
        )
        await relaunched.waitForIdleForTesting()

        #expect(requests.isEmpty)
        let state = relaunched.state(for: uncertain.chat)
        guard case let .failed(message) = state.phase else {
            Issue.record("Expected the uncertain-ownership state to stay actionable")
            return
        }
        #expect(message.contains("may have been accepted"))
        let owned = try #require(relaunched.source(for: state, in: uncertain.chat))
        #expect(owned == uncertain)

        await relaunched.retry(owned, transport: transport)
        await relaunched.waitForIdleForTesting()

        #expect(requests.first?.clientRequestId == request.clientRequestId)
        #expect(requests.filter { $0.clientRequestId == request.clientRequestId }.count == 1)
        #expect(requests.contains { $0.context.source.instanceId == latest.responseID })
        let replayed = try #require(
            relaunched.briefs(for: uncertain.chat).first { $0.source.responseID == uncertain.responseID }
        )
        #expect(replayed.responseBriefLength == .medium)
        #expect(relaunched.state(for: uncertain.chat).phase == .idle)
    }

    @Test("Retry resumes a durable length replacement exactly once when no card exists")
    func retryResumesPendingReplacementWithoutCard() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-retry-no-card")
        var blockedRequests: [AssistantRequest] = []
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                blockedRequests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))

        // Changing length against an old companion leaves exactly one durable
        // replacement intent and sends nothing.
        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: oldTransport
        )
        await coordinator.waitForIdleForTesting()
        #expect(blockedRequests.isEmpty)
        guard case .upgradeRequired = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected the configurable-length upgrade notice")
            return
        }
        let awaiting = try await fixture.persistence.snapshot()
        #expect(awaiting.pendingRegenerations[source.chat.id]?.length == .medium)

        // Retry after upgrading must dispatch the captured intent instead of an
        // ordinary job the intent would pay for again on the next poll.
        var requests: [AssistantRequest] = []
        let upgradedTransport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        await coordinator.retry(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 1)
        #expect(requests.first?.responseBriefLength == .medium)
        #expect(coordinator.state(for: source.chat).phase == .idle)
        #expect(coordinator.briefs(for: source.chat).count == 1)
        let consumed = try await fixture.persistence.snapshot()
        #expect(consumed.pendingRegenerations.isEmpty)
        #expect(consumed.receipts.isEmpty)

        // Polling and a relaunch never replay the deliberate replacement.
        await coordinator.observe(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)

        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        )
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        await relaunched.observe(source, transport: upgradedTransport)
        await relaunched.waitForIdleForTesting()
        #expect(requests.count == 1)
        #expect(relaunched.briefs(for: source.chat).count == 1)
    }

    @Test("Retry resumes the pending length replacement instead of stopping at regenerateNeeded")
    func retryResumesPendingReplacementWithExistingCard() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-retry-card")
        var requests: [AssistantRequest] = []
        let upgradedTransport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)

        // A companion downgrade clears cached support, so the length change
        // cannot reach the old server even though a card already exists.
        await coordinator.connectionDidChange()
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: oldTransport
        )
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)
        guard case .upgradeRequired = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected the configurable-length upgrade notice")
            return
        }
        let blocked = try await fixture.persistence.snapshot()
        #expect(blocked.pendingRegenerations[source.chat.id]?.length == .long)

        // Retry must perform the queued deliberate replacement rather than
        // only presenting guidance that leaves the intent to fire later.
        await coordinator.retry(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()

        #expect(requests.count == 2)
        #expect(requests.last?.responseBriefLength == .long)
        #expect(coordinator.state(for: source.chat).phase == .idle)
        #expect(coordinator.briefs(for: source.chat).count == 2)
        let consumed = try await fixture.persistence.snapshot()
        #expect(consumed.pendingRegenerations.isEmpty)

        await coordinator.observe(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 2)

        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        )
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        await relaunched.observe(source, transport: upgradedTransport)
        await relaunched.waitForIdleForTesting()
        #expect(requests.count == 2)
        #expect(relaunched.briefs(for: source.chat).count == 2)
    }

    @Test("Refreshing support resumes the pending replacement instead of an ordinary duplicate")
    func refreshSupportResumesPendingReplacement() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-refresh-support")
        var blockedRequests: [AssistantRequest] = []
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                blockedRequests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: oldTransport)
        await coordinator.waitForIdleForTesting()
        #expect(blockedRequests.isEmpty)

        await coordinator.changeLength(
            .medium,
            chat: source.chat,
            selectedSource: source,
            transport: oldTransport
        )
        await coordinator.waitForIdleForTesting()
        #expect(blockedRequests.isEmpty)
        let awaiting = try await fixture.persistence.snapshot()
        #expect(awaiting.pendingRegenerations[source.chat.id]?.length == .medium)

        var requests: [AssistantRequest] = []
        let upgradedTransport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        await coordinator.refreshSupport(
            machineID: source.chat.machineID,
            transport: upgradedTransport
        )
        await coordinator.waitForIdleForTesting()

        // The waiting selection owns the one submission; the refresh must not
        // create an ordinary job the intent would pay for again after it.
        #expect(requests.count == 1)
        #expect(requests.first?.responseBriefLength == .medium)
        let consumed = try await fixture.persistence.snapshot()
        #expect(consumed.pendingRegenerations.isEmpty)

        await coordinator.observe(source, transport: upgradedTransport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)
        #expect(coordinator.briefs(for: source.chat).count == 1)
    }

    @Test("Disabling and re-enabling during the intent save discards the obsolete replacement")
    func disableDuringIntentSaveDiscardsObsoleteReplacement() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let selected = fixture.source(responseID: "entry-barrier-selected")
        let latest = fixture.source(
            responseID: "entry-barrier-latest",
            text: selected.text + " A later synthetic follow-up with more detail.",
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        var requests: [AssistantRequest] = []
        let transport = fixture.transport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(latest.chat))

        var release: CheckedContinuation<Void, Never>?
        var barrierStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { barrierStarted = $0 }
        coordinator.intentPersistenceBarrier = {
            barrierStarted?.yield()
            await withCheckedContinuation { release = $0 }
        }

        let change = Task { @MainActor in
            await coordinator.changeLength(
                .long,
                chat: selected.chat,
                selectedSource: selected,
                transport: transport
            )
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        // The durable write is still suspended when the chat is disabled and
        // immediately re-enabled, so the captured selection is obsolete and
        // must never be published or resumed.
        await coordinator.disable(selected.chat, transport: transport)
        #expect(coordinator.enable(selected.chat))
        release?.resume()
        await change.value
        coordinator.intentPersistenceBarrier = nil
        await coordinator.waitForIdleForTesting()

        #expect(requests.isEmpty)
        let discarded = try await fixture.persistence.snapshot()
        #expect(discarded.pendingRegenerations.isEmpty)

        // Re-enabling observes the latest completion. Only that new answer may
        // generate; the discarded intent never resurfaces for the selection.
        await coordinator.observe(latest, transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.context.source.instanceId == latest.responseID })
        #expect(coordinator.briefs(for: selected.chat).count == 1)

        await coordinator.observeSources([selected, latest], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(requests.count == 1)

        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        )
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(selected.chat))
        await relaunched.observeSources([selected, latest], transport: transport)
        await relaunched.waitForIdleForTesting()
        #expect(requests.count == 1)
        #expect(relaunched.briefs(for: selected.chat).count == 1)
        #expect(relaunched.briefs(for: selected.chat).first?.source.responseID == latest.responseID)
    }

    @Test("A rejected stale intent write cannot be resumed by an immediate relaunch")
    func staleIntentWriteCannotSurviveRelaunch() async throws {
        let fixture = try LengthFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-stale-relaunch")
        var requests: [AssistantRequest] = []
        // The old companion blocks the newest selection in preflight, so this
        // regression isolates durable intent ordering instead of submissions.
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )
        #expect(coordinator.enable(source.chat))

        var releaseMedium: CheckedContinuation<Void, Never>?
        var barrierStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { barrierStarted = $0 }
        var suspendFirstWrite = true
        coordinator.intentPersistenceBarrier = {
            guard suspendFirstWrite else { return }
            suspendFirstWrite = false
            barrierStarted?.yield()
            await withCheckedContinuation { releaseMedium = $0 }
        }

        let mediumChange = Task { @MainActor in
            await coordinator.changeLength(
                .medium,
                chat: source.chat,
                selectedSource: source,
                transport: oldTransport
            )
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        // The newer Long selection lands first while the older Medium write is
        // still suspended.
        await coordinator.changeLength(
            .long,
            chat: source.chat,
            selectedSource: source,
            transport: oldTransport
        )
        let newest = try await fixture.persistence.snapshot()
        #expect(newest.pendingRegenerations[source.chat.id]?.length == .long)
        #expect((newest.pendingRegenerations[source.chat.id]?.revision ?? 0) > 0)

        // The delayed older write resumes and must be rejected atomically
        // before any coordinator cleanup could run.
        releaseMedium?.resume()
        await mediumChange.value
        coordinator.intentPersistenceBarrier = nil

        // Restore immediately from disk, exactly as a relaunch would, and
        // verify only the newest selection survives.
        let relaunchedPersistence = ResponseBriefPersistence(
            url: fixture.folder.appending(path: "cache.json")
        )
        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: relaunchedPersistence
        )
        relaunched.selectModel("provider/brief-model")
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        #expect(relaunched.length == .long)
        let restored = try await relaunchedPersistence.snapshot()
        #expect(restored.pendingRegenerations[source.chat.id]?.length == .long)

        await relaunched.observe(source, transport: oldTransport)
        await relaunched.waitForIdleForTesting()
        #expect(requests.isEmpty)
        let final = try await relaunchedPersistence.snapshot()
        #expect(final.pendingRegenerations[source.chat.id]?.length == .long)
        #expect(final.pendingRegenerations[source.chat.id]?.revision == restored.pendingRegenerations[source.chat.id]?.revision)
    }
}

@MainActor
private final class LengthFixture {
    let folder: URL
    let suiteName: String
    let defaults: UserDefaults
    let persistence: ResponseBriefPersistence
    let briefModel = PiAvailableModel(
        provider: "provider",
        modelID: "brief-model",
        name: "Synthetic brief model",
        reasoning: true,
        contextWindow: 64_000
    )
    let otherModel = PiAvailableModel(
        provider: "provider",
        modelID: "other-model",
        name: "Synthetic other model",
        reasoning: false,
        contextWindow: 32_000
    )
    let text = Array(repeating: "Synthetic completed answer detail.", count: 20).joined(separator: " ")
    let validJSON = #"{"version":1,"title":"Synthetic result","summary":"The answer has many details.","points":[{"text":"Read the answer.","startLine":1,"endLine":1}],"details":[]}"#

    init() throws {
        let newFolder = FileManager.default.temporaryDirectory.appending(
            path: "response-brief-length-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let newSuiteName = "response-brief-length-\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuiteName))
        folder = newFolder
        suiteName = newSuiteName
        defaults = newDefaults
        persistence = ResponseBriefPersistence(url: newFolder.appending(path: "cache.json"))
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        newDefaults.removePersistentDomain(forName: newSuiteName)
    }

    func coordinator() -> ResponseBriefCoordinator {
        let coordinator = ResponseBriefCoordinator(defaults: defaults, persistence: persistence)
        coordinator.selectModel("provider/brief-model")
        return coordinator
    }

    func source(
        responseID: String,
        text: String? = nil,
        chat: ResponseBriefChatIdentity? = nil,
        responseTimestamp: Date? = Date(timeIntervalSince1970: 1_800_000_100),
        userTimestamp: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ResponseBriefSource {
        let resolvedText = text ?? self.text
        return ResponseBriefSource(
            chat: chat ?? .init(
                machineID: "synthetic-machine",
                paneID: "w1:p2",
                sessionID: "synthetic-session"
            ),
            responseID: responseID,
            text: resolvedText,
            currentUserText: "Synthetic question",
            previousUserText: nil,
            previousAssistantText: nil,
            identity: ResponseBriefIdentityEvidence(
                responseText: resolvedText,
                responseTimestamp: responseTimestamp,
                userText: "Synthetic question",
                userTimestamp: userTimestamp
            )
        )
    }

    func run(
        status: HeadlessAgentRunStatus,
        response: String?,
        error: String? = nil
    ) -> HeadlessAgentRun {
        HeadlessAgentRun(
            id: "agr_synthetic0001",
            status: status,
            mode: .ask,
            model: "provider/brief-model",
            thinkingLevel: "low",
            prompt: "synthetic",
            cwd: nil,
            response: response,
            error: error,
            createdAt: "2026-09-17T00:00:00Z",
            startedAt: "2026-09-17T00:00:00Z",
            finishedAt: status.isTerminal ? "2026-09-17T00:00:01Z" : nil,
            sessionID: "private-brief-session",
            sessionFile: nil,
            costUSD: 0,
            promotedWorkspaceID: nil,
            promotedPaneID: nil,
            attachments: nil,
            steps: nil,
            stepsTruncated: nil,
            threadRootRunId: nil
        )
    }

    func capabilities() -> AssistantCapabilities {
        AssistantCapabilities(
            profiles: ["response-brief-v1"],
            responseBriefs: .init(
                version: 1,
                lengthPolicyVersion: ResponseBriefLength.policyVersion,
                lengthOptions: ResponseBriefLength.options
            )
        )
    }

    func transport(
        start: @escaping (AssistantRequest) async throws -> HeadlessAgentRun,
        fetch: @escaping (String) async throws -> HeadlessAgentRun
    ) -> ResponseBriefTransport {
        ResponseBriefTransport(
            capabilities: { _ in self.capabilities() },
            models: { _ in
                AgentModelCatalogResponse(
                    ok: true,
                    models: [self.briefModel, self.otherModel],
                    defaultModel: nil
                )
            },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, request in try await start(request) },
            fetch: { _, id in try await fetch(id) },
            cancel: { _, id in self.run(status: .cancelled, response: nil, error: "cancelled \(id)") }
        )
    }

    func oldServerTransport(
        start: @escaping (AssistantRequest) async throws -> HeadlessAgentRun,
        fetch: @escaping (String) async throws -> HeadlessAgentRun
    ) -> ResponseBriefTransport {
        ResponseBriefTransport(
            capabilities: { _ in AssistantCapabilities(profiles: ["response-brief-v1"]) },
            models: { _ in
                AgentModelCatalogResponse(
                    ok: true,
                    models: [self.briefModel, self.otherModel],
                    defaultModel: nil
                )
            },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, request in try await start(request) },
            fetch: { _, id in try await fetch(id) },
            cancel: { _, id in self.run(status: .cancelled, response: nil, error: "cancelled \(id)") }
        )
    }

    func legacyGenerationID(for source: ResponseBriefSource, model: String?, thinkingLevel: String?) -> String {
        let material = [
            source.chat.machineID,
            source.chat.sessionID,
            source.responseID,
            source.sourceHash,
            String(ResponseBriefLimits.templateVersion),
            model ?? "default",
            thinkingLevel ?? "default",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
