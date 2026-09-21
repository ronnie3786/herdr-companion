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

        // Relaunch against an old server: the saved receipt still reconciles.
        let relaunchedPersistence = ResponseBriefPersistence(url: fixture.folder.appending(path: "cache.json"))
        let relaunched = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: relaunchedPersistence
        )
        relaunched.selectModel("provider/brief-model")
        relaunched.runPollDelay = .zero
        #expect(relaunched.enable(source.chat))
        var fetches = 0
        let oldTransport = fixture.oldServerTransport(
            start: { _ in
                Issue.record("An accepted receipt must reconcile without a new submission")
                throw APIError.invalidResponse
            },
            fetch: { _ in
                fetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )
        await relaunched.retry(source, transport: oldTransport)
        await relaunched.waitForIdleForTesting()

        #expect(fetches == 1)
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

        coordinator.disable(source.chat, transport: transport)
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
