import CryptoKit
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief baseline recovery", .serialized)
@MainActor
struct ResponseBriefRecoveryTests {
    @Test("A live identifier reconciles to its persisted entry without a duplicate paid request")
    func liveToPersistedContinuationReconciles() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let live = fixture.source(responseID: "live:synthetic:1800000100")
        let persisted = fixture.source(responseID: "entry-a1", text: live.text)
        var starts = 0
        let transport = fixture.transport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        #expect(coordinator.enable(live.chat))
        await coordinator.observe(live, transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts == 1)

        await coordinator.observeSources([persisted], transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        #expect(coordinator.state(for: live.chat).phase == .idle)
        #expect(coordinator.briefs(for: live.chat).map(\.source.responseID) == [live.responseID])

        let stored = try await fixture.persistence.snapshot()
        #expect(stored.responseCursorByChatID[live.chat.id] == persisted.responseID)
        #expect(stored.baselineAnchors[live.chat.id]?.responseID == persisted.responseID)
        #expect(stored.verifiedAliases[live.chat.id]?.contains {
            $0.aliasID == live.responseID && $0.canonicalID == persisted.responseID
        } == true)

        // A second snapshot at the canonical baseline stays quiet.
        await coordinator.observeSources([persisted], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts == 1)
        #expect(coordinator.state(for: live.chat).phase == .idle)
    }

    @Test("A persisted baseline never duplicates when the live projection is observed later")
    func persistedBaselineThenLiveProjection() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let persisted = fixture.source(responseID: "entry-a1")
        let live = fixture.source(responseID: "live:synthetic:1800000100", text: persisted.text)
        var starts = 0
        let transport = fixture.transport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        #expect(coordinator.enable(persisted.chat))
        await coordinator.observeSources([persisted], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts == 1)

        await coordinator.observe(live, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        #expect(coordinator.briefs(for: persisted.chat).count == 1)
        #expect(coordinator.state(for: persisted.chat).phase == .idle)
    }

    @Test("A legacy baseline with owned identity evidence migrates only when it verifies")
    func legacyBaselineMigratesWithEvidence() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let live = fixture.source(responseID: "live:synthetic:1800000100")
        let persisted = fixture.source(responseID: "entry-a1", text: live.text)
        let legacyID = fixture.legacyGenerationID(for: live, model: "provider/brief-model", thinkingLevel: nil)
        try await fixture.persistence.saveRecord(.init(
            id: legacyID,
            source: live,
            brief: fixture.validBrief,
            model: "provider/brief-model",
            thinkingLevel: nil,
            createdAt: .now
        ))
        // Predecessor baseline: a cursor without a durable anchor.
        try await fixture.persistence.advanceCursor(
            chatID: live.chat.id,
            responseID: live.responseID
        )
        let coordinator = fixture.coordinator()
        #expect(coordinator.enable(live.chat))
        var starts = 0
        let transport = fixture.transport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        await coordinator.observeSources([persisted], transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 0)
        #expect(coordinator.state(for: live.chat).phase == .idle)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.responseCursorByChatID[live.chat.id] == persisted.responseID)
        #expect(stored.verifiedAliases[live.chat.id]?.first?.canonicalID == persisted.responseID)
    }

    @Test("An unmatched baseline warns and confirmed recovery generates only the latest")
    func unmatchedBaselineRecoveryIsLatestOnly() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let older = fixture.source(responseID: "entry-a0")
        let latest = fixture.source(
            responseID: "entry-a1",
            text: older.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        try await fixture.persistence.advanceCursor(
            chatID: older.chat.id,
            responseID: "missing-answer"
        )
        let coordinator = fixture.coordinator()
        #expect(coordinator.enable(older.chat))
        var starts: [String] = []
        let transport = fixture.transport(
            snapshot: fixture.snapshot(for: [older, latest]),
            start: { request in
                starts.append(request.context.source.instanceId)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        await coordinator.observeSources([older, latest], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts.isEmpty)
        guard case let .baselineUnmatched(message) = coordinator.state(for: older.chat).phase else {
            Issue.record("Expected the unmatched-baseline warning")
            return
        }
        #expect(message.contains("could not be matched"))
        let before = try await fixture.persistence.snapshot()
        #expect(before.responseCursorByChatID[older.chat.id] == "missing-answer")

        await coordinator.restartBriefsFromLatest(older.chat, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == [latest.responseID])
        #expect(coordinator.state(for: older.chat).phase == .idle)
        #expect(coordinator.briefs(for: older.chat).map(\.source.responseID) == [latest.responseID])
        let after = try await fixture.persistence.snapshot()
        #expect(after.responseCursorByChatID[older.chat.id] == latest.responseID)
        #expect(after.baselineAnchors[older.chat.id]?.responseID == latest.responseID)

        // Polling after recovery never recreates the warning or backfills history.
        await coordinator.observeSources([older, latest], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(coordinator.state(for: older.chat).phase == .idle)
        #expect(starts == [latest.responseID])
    }

    @Test("Identical text without timestamp evidence never reconciles or backfills")
    func contentOnlyAmbiguityNeverReconciles() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let first = fixture.source(responseID: "live:synthetic:1", identity: false, responseTimestamp: nil)
        let second = fixture.source(
            responseID: "live:synthetic:2",
            text: first.text,
            identity: false,
            responseTimestamp: nil
        )
        try await fixture.persistence.advanceCursor(
            chatID: first.chat.id,
            responseID: "missing-answer"
        )
        let coordinator = fixture.coordinator()
        #expect(coordinator.enable(first.chat))
        var starts: [String] = []
        let transport = fixture.transport(
            snapshot: fixture.snapshot(for: [first, second]),
            start: { request in
                starts.append(request.context.source.instanceId)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        await coordinator.observeSources([first, second], transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts.isEmpty)
        guard case .baselineUnmatched = coordinator.state(for: first.chat).phase else {
            Issue.record("Content-only candidates must stay ambiguous")
            return
        }

        await coordinator.restartBriefsFromLatest(first.chat, transport: transport)
        await coordinator.waitForIdleForTesting()
        #expect(starts == [second.responseID])
    }

    @Test("Recovery reconciles an outstanding receipt before generating the latest")
    func recoveryPreservesOutstandingOwnership() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let prior = fixture.source(responseID: "entry-prior", identity: false, responseTimestamp: nil)
        let older = fixture.source(responseID: "entry-a0")
        let latest = fixture.source(
            responseID: "entry-a1",
            text: older.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_300),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let request = try ResponseBriefRequestBuilder.request(
            for: prior,
            model: "provider/brief-model",
            thinkingLevel: nil
        )
        try await fixture.persistence.saveReceipt(.init(
            id: fixture.legacyGenerationID(for: prior, model: "provider/brief-model", thinkingLevel: nil),
            source: prior,
            request: request,
            runID: "agr_synthetic0001",
            createdAt: .now
        ))
        try await fixture.persistence.advanceCursor(
            chatID: prior.chat.id,
            responseID: "missing-answer"
        )
        let coordinator = fixture.coordinator()
        #expect(coordinator.enable(prior.chat))
        var starts = 0
        var fetches = 0
        let transport = fixture.transport(
            snapshot: fixture.snapshot(for: [older, latest]),
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in
                fetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )

        await coordinator.restartBriefsFromLatest(prior.chat, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        #expect(fetches == 1)
        let responseIDs = Set(coordinator.briefs(for: prior.chat).map(\.source.responseID))
        #expect(responseIDs == [prior.responseID, latest.responseID])
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.receipts.isEmpty)
        #expect(stored.responseCursorByChatID[prior.chat.id] == latest.responseID)
    }

    @Test("A legacy receipt replays its exact prompt on an old server without length capability")
    func legacyReceiptReconcilesWithoutLengthCapability() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let source = fixture.source(responseID: "entry-legacy", identity: false, responseTimestamp: nil)
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: "provider/brief-model",
            thinkingLevel: nil
        )
        #expect(request.responseBriefLength == nil)
        #expect(request.prompt == ResponseBriefRequestBuilder.prompt)
        try await fixture.persistence.saveReceipt(.init(
            id: fixture.legacyGenerationID(for: source, model: "provider/brief-model", thinkingLevel: nil),
            source: source,
            request: request,
            runID: "agr_synthetic0001",
            createdAt: .now
        ))
        let coordinator = fixture.coordinator()
        #expect(coordinator.enable(source.chat))
        var starts = 0
        var fetches = 0
        let transport = fixture.oldServerTransport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in
                fetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )

        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 0)
        #expect(fetches == 1)
        #expect(coordinator.state(for: source.chat).phase == .idle)
        let record = try #require(coordinator.briefs(for: source.chat).first)
        #expect(record.responseBriefLength == nil)
        #expect(record.responseBriefLengthPolicyVersion == nil)
        let stored = try await fixture.persistence.snapshot()
        #expect(stored.receipts.isEmpty)
    }

    @Test("An old server blocks a new-policy request with an upgrade notice and retry works after upgrade")
    func oldServerBlocksNewPolicyWithUpgradeNotice() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "entry-upgrade")
        var requests: [AssistantRequest] = []
        let oldTransport = fixture.oldServerTransport(
            start: { request in
                requests.append(request)
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        #expect(coordinator.enable(source.chat))
        await coordinator.observe(source, transport: oldTransport)
        await coordinator.waitForIdleForTesting()

        #expect(requests.isEmpty)
        guard case let .upgradeRequired(message) = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected the configurable-length upgrade notice")
            return
        }
        #expect(message.contains("companion"))

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
        #expect(requests.first?.responseBriefLength == .minimal)
        #expect(requests.first?.prompt == ResponseBriefRequestBuilder.lengthPrompt)
        #expect(coordinator.state(for: source.chat).phase == .idle)
    }

    @Test("Repeated identical answers stay distinct through timestamps")
    func repeatedIdenticalAnswersStayDistinct() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let first = fixture.source(responseID: "entry-text-1", text: "Done.")
        let second = fixture.source(
            responseID: "entry-text-2",
            text: "Done.",
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_500),
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_400)
        )
        var starts: [String] = []
        let transport = fixture.transport(
            start: { request in
                starts.append(request.context.source.instanceId)
                return fixture.run(status: .completed, response: fixture.shortValidJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.shortValidJSON) }
        )

        #expect(coordinator.enable(first.chat))
        await coordinator.observeSources([first], transport: transport)
        await coordinator.waitForIdleForTesting()
        await coordinator.observeSources([first, second], transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == [first.responseID, second.responseID])
        #expect(coordinator.briefs(for: first.chat).count == 2)
        #expect(coordinator.state(for: first.chat).phase == .idle)
    }
}

@MainActor
private final class RecoveryFixture {
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

    let text = Array(repeating: "Synthetic completed answer detail.", count: 20).joined(separator: " ")
    let validJSON = #"{"version":1,"title":"Synthetic result","summary":"The answer has many details.","points":[{"text":"Read the answer.","startLine":1,"endLine":1}],"details":[]}"#
    let shortValidJSON = #"{"version":1,"title":"T","summary":"Done.","points":[],"details":[]}"#

    init() throws {
        let newFolder = FileManager.default.temporaryDirectory.appending(
            path: "response-brief-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let newSuiteName = "response-brief-recovery-\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuiteName))
        folder = newFolder
        suiteName = newSuiteName
        defaults = newDefaults
        persistence = ResponseBriefPersistence(url: newFolder.appending(path: "cache.json"))
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        newDefaults.removePersistentDomain(forName: newSuiteName)
    }

    var validBrief: ResponseBrief {
        ResponseBrief(
            version: 1,
            title: "Synthetic result",
            summary: "The answer has many details.",
            points: [.init(text: "Read the answer.", startLine: 1, endLine: 1)],
            details: []
        )
    }

    func coordinator() -> ResponseBriefCoordinator {
        let coordinator = ResponseBriefCoordinator(defaults: defaults, persistence: persistence)
        coordinator.selectModel("provider/brief-model")
        return coordinator
    }

    func source(
        responseID: String,
        text: String? = nil,
        identity: Bool = true,
        responseTimestamp: Date? = Date(timeIntervalSince1970: 1_800_000_100),
        userTimestamp: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ResponseBriefSource {
        let resolvedText = text ?? self.text
        return ResponseBriefSource(
            chat: .init(
                machineID: "synthetic-machine",
                paneID: "w1:p2",
                sessionID: "synthetic-session"
            ),
            responseID: responseID,
            text: resolvedText,
            currentUserText: "Synthetic question",
            previousUserText: nil,
            previousAssistantText: nil,
            identity: identity
                ? ResponseBriefIdentityEvidence(
                    responseText: resolvedText,
                    responseTimestamp: responseTimestamp,
                    userText: "Synthetic question",
                    userTimestamp: userTimestamp
                )
                : nil
        )
    }

    func snapshot(for sources: [ResponseBriefSource]) -> PiConversationSnapshot {
        let sessionID = sources.first?.chat.sessionID ?? "synthetic-session"
        var entries: [[String: Any]] = []
        for source in sources {
            var userMessage: [String: Any] = [
                "role": "user",
                "content": source.currentUserText ?? "Synthetic question",
            ]
            if let timestamp = source.identity?.userTimestamp {
                userMessage["timestamp"] = timestamp.timeIntervalSince1970 * 1_000
            }
            var userEntry: [String: Any] = [
                "type": "message",
                "id": "user-\(source.responseID)",
                "message": userMessage,
            ]
            if let timestamp = source.identity?.userTimestamp {
                userEntry["timestamp"] = timestamp.timeIntervalSince1970 * 1_000
            }
            entries.append(userEntry)

            var assistantMessage: [String: Any] = [
                "role": "assistant",
                "stopReason": "stop",
                "content": [["type": "text", "text": source.text]],
            ]
            if let timestamp = source.identity?.responseTimestamp {
                assistantMessage["timestamp"] = timestamp.timeIntervalSince1970 * 1_000
            }
            var assistantEntry: [String: Any] = [
                "type": "message",
                "id": source.responseID,
                "message": assistantMessage,
            ]
            if let timestamp = source.identity?.responseTimestamp {
                assistantEntry["timestamp"] = timestamp.timeIntervalSince1970 * 1_000
            }
            entries.append(assistantEntry)
        }
        let root: [String: Any] = [
            "protocol": ["name": "herdr.pi.semantic", "version": 1],
            "paneId": "w1:p2",
            "available": true,
            "connected": true,
            "session": ["id": sessionID],
            "state": ["isStreaming": false],
            "entries": entries,
            "pendingInteractions": [],
            "cursor": "0",
            "oldestCursor": "0",
            "truncated": false,
        ]
        // The synthetic snapshot is constructed from in-memory values; a
        // serialization failure would be a test-authoring error.
        let data = try! JSONSerialization.data(withJSONObject: root)
        return try! JSONDecoder().decode(PiConversationSnapshot.self, from: data)
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
        snapshot: PiConversationSnapshot? = nil,
        start: @escaping (AssistantRequest) async throws -> HeadlessAgentRun,
        fetch: @escaping (String) async throws -> HeadlessAgentRun
    ) -> ResponseBriefTransport {
        ResponseBriefTransport(
            capabilities: { _ in self.capabilities() },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [self.briefModel], defaultModel: nil) },
            fetchSnapshot: { _ in
                guard let snapshot else { throw APIError.invalidResponse }
                return snapshot
            },
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
            models: { _ in AgentModelCatalogResponse(ok: true, models: [self.briefModel], defaultModel: nil) },
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
