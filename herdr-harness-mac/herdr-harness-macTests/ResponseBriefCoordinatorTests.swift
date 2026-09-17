import CryptoKit
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief coordinator", .serialized)
@MainActor
struct ResponseBriefCoordinatorTests {
    @Test("Duplicate observations submit once and cache one record")
    func deduplicatesSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let source = fixture.source(responseID: "answer-1", text: "line one\nline two")
        var starts = 0
        let transport = fixture.transport(
            start: { request in
                starts += 1
                #expect(request.model == "provider/brief-model")
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        #expect(coordinator.briefs(for: source.chat).count == 1)
        #expect(coordinator.briefs(for: source.chat).first?.source.text == source.text)
    }

    @Test("Disabled observation waits for opt-in and then uses the preselected configuration")
    func preselectsConfigurationBeforeOptIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = ResponseBriefCoordinator(defaults: fixture.defaults, persistence: fixture.persistence)
        coordinator.runPollDelay = .zero
        coordinator.selectModel("provider/brief-model")
        coordinator.selectThinkingLevel("high")
        let source = fixture.source(responseID: "answer-opt-in", text: "line one\nline two")
        var starts = 0
        var submittedRequest: AssistantRequest?
        let transport = fixture.transport(
            start: { request in
                starts += 1
                submittedRequest = request
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 0)
        #expect(coordinator.enable(source.chat))

        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        #expect(submittedRequest?.model == "provider/brief-model")
        #expect(submittedRequest?.thinkingLevel == "high")
    }

    @Test("Accepted run receipt resumes by polling without another POST")
    func resumesAcceptedReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.source(responseID: "answer-replay", text: "line one\nline two")
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: "provider/brief-model",
            thinkingLevel: nil,
            clientRequestID: "durable-request-id"
        )
        let firstProcess = fixture.coordinator()
        #expect(firstProcess.enable(source.chat))
        try await fixture.persistence.saveReceipt(.init(
            id: fixture.generationID(for: source, model: "provider/brief-model", thinkingLevel: nil),
            source: source,
            request: request,
            runID: "agr_synthetic0001",
            createdAt: .now
        ))

        var resumedStarts = 0
        var resumedFetches = 0
        let restoredPersistence = ResponseBriefPersistence(
            url: fixture.folder.appending(path: "cache.json")
        )
        let resumed = ResponseBriefCoordinator(
            defaults: fixture.defaults,
            persistence: restoredPersistence
        )
        #expect(resumed.isEnabled(source.chat))
        resumed.runPollDelay = .zero
        let resumedTransport = fixture.transport(
            start: { _ in
                resumedStarts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in
                resumedFetches += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )
        await resumed.observe(source, transport: resumedTransport)
        await resumed.waitForIdleForTesting()

        #expect(resumedStarts == 0)
        #expect(resumedFetches == 1)
        #expect(resumed.briefs(for: source.chat).count == 1)
        let stored = try await ResponseBriefPersistence(
            url: fixture.folder.appending(path: "cache.json")
        ).snapshot()
        #expect(stored.records.map(\.source.responseID) == [source.responseID])
        #expect(stored.receipts.isEmpty)
    }

    @Test("Disabling an enabled chat cancels its accepted owned run")
    func disableCancelsAcceptedRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .seconds(100)
        let source = fixture.source(responseID: "answer-cancel", text: "line one\nline two")
        var startContinuation: AsyncStream<Void>.Continuation?
        let didStart = AsyncStream<Void> { startContinuation = $0 }
        var cancelContinuation: AsyncStream<String>.Continuation?
        let didCancel = AsyncStream<String> { cancelContinuation = $0 }
        let transport = ResponseBriefTransport(
            capabilities: { _ in AssistantCapabilities(profiles: ["response-brief-v1"]) },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [fixture.briefModel], defaultModel: nil) },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, _ in
                startContinuation?.yield()
                return fixture.run(status: .queued, response: nil)
            },
            fetch: { _, _ in fixture.run(status: .queued, response: nil) },
            cancel: { _, runID in
                cancelContinuation?.yield(runID)
                return fixture.run(status: .cancelled, response: nil)
            }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)
        var startIterator = didStart.makeAsyncIterator()
        _ = await startIterator.next()
        #expect(await waitUntil { coordinator.state(for: source.chat).runID != nil })
        coordinator.disable(source.chat, transport: transport)
        var cancelIterator = didCancel.makeAsyncIterator()
        let cancelledID = await cancelIterator.next()

        #expect(cancelledID == "agr_synthetic0001")
        #expect(!coordinator.isEnabled(source.chat))
        await coordinator.waitForIdleForTesting()
    }

    @Test("A changed session identity is opted out instead of inherited")
    func newSessionDoesNotInheritOptIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let original = fixture.source(responseID: "old", text: "old")
        let replacement = ResponseBriefSource(
            chat: .init(machineID: original.chat.machineID, paneID: original.chat.paneID, sessionID: "new-session"),
            responseID: "new",
            text: "new",
            currentUserText: "new question",
            previousUserText: nil,
            previousAssistantText: nil
        )

        coordinator.enable(original.chat)
        #expect(coordinator.isEnabled(original.chat))
        #expect(!coordinator.isEnabled(replacement.chat))
    }

    @Test("New completions stay FIFO while one chat run is active")
    func queuesNewCompletionsFIFO() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let first = fixture.source(responseID: "answer-a", text: "line one\nline two")
        let second = fixture.source(responseID: "answer-b", text: "line one\nline two")
        var startedIDs: [String] = []
        var didStartContinuation: AsyncStream<String>.Continuation?
        let didStart = AsyncStream<String> { didStartContinuation = $0 }
        var releaseContinuation: AsyncStream<Void>.Continuation?
        let release = AsyncStream<Void> { releaseContinuation = $0 }
        let transport = fixture.transport(
            start: { request in
                startedIDs.append(request.context.source.instanceId)
                didStartContinuation?.yield(request.context.source.instanceId)
                if request.context.source.instanceId == "answer-a" {
                    var iterator = release.makeAsyncIterator()
                    _ = await iterator.next()
                }
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        coordinator.enable(first.chat)
        await coordinator.observe(first, transport: transport)
        var startedIterator = didStart.makeAsyncIterator()
        let firstStartedID = await startedIterator.next()
        #expect(firstStartedID == "answer-a")
        await coordinator.observe(second, transport: transport)
        #expect(startedIDs == ["answer-a"])
        releaseContinuation?.yield()
        await coordinator.waitForIdleForTesting()

        #expect(startedIDs == ["answer-a", "answer-b"])
        #expect(coordinator.briefs(for: first.chat).map(\.source.responseID) == ["answer-b", "answer-a"])
    }

    @Test("A cancelled old operation keeps its slot until POST ownership reconciles")
    func operationTokenProtectsReenabledRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.runPollDelay = .zero
        let first = fixture.source(responseID: "answer-old", text: "line one\nline two")
        let second = fixture.source(responseID: "answer-new", text: "line one\nline two")
        var starts: [String] = []
        var fetches: [String] = []
        var startContinuation: CheckedContinuation<Void, Never>?
        var didStartContinuation: AsyncStream<Void>.Continuation?
        let didStart = AsyncStream<Void> { didStartContinuation = $0 }
        let transport = fixture.transport(
            start: { request in
                starts.append(request.context.source.instanceId)
                if request.context.source.instanceId == "answer-old" {
                    didStartContinuation?.yield()
                    await withCheckedContinuation { startContinuation = $0 }
                    return fixture.run(status: .queued, response: nil)
                }
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { runID in
                fetches.append(runID)
                return fixture.run(status: .completed, response: fixture.validJSON)
            }
        )

        coordinator.enable(first.chat)
        await coordinator.observe(first, transport: transport)
        var startedIterator = didStart.makeAsyncIterator()
        _ = await startedIterator.next()
        coordinator.disable(first.chat, transport: transport)
        #expect(coordinator.enable(first.chat))
        await coordinator.observe(second, transport: transport)
        #expect(starts == ["answer-old"])

        startContinuation?.resume()
        await coordinator.waitForIdleForTesting()

        #expect(starts == ["answer-old", "answer-new"])
        #expect(fetches.isEmpty)
        #expect(coordinator.briefs(for: first.chat).map(\.source.responseID) == ["answer-new"])
    }

    @Test("An unavailable explicit model blocks dispatch without fallback")
    func unavailableModelIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let source = fixture.source(responseID: "answer-model", text: "line one\nline two")
        var starts = 0
        let transport = ResponseBriefTransport(
            capabilities: { _ in AssistantCapabilities(profiles: ["response-brief-v1"]) },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [], defaultModel: nil) },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, _ in starts += 1; return fixture.run(status: .completed, response: fixture.validJSON) },
            fetch: { _, _ in fixture.run(status: .completed, response: fixture.validJSON) },
            cancel: { _, _ in fixture.run(status: .cancelled, response: nil) }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 0)
        guard case let .failed(message) = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected unavailable-model failure")
            return
        }
        #expect(message.contains("unavailable"))
    }

    @Test("Server default remains nil instead of becoming a global explicit model")
    func serverDefaultRemainsNil() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = ResponseBriefCoordinator(defaults: fixture.defaults, persistence: fixture.persistence)
        let transport = fixture.transport(
            start: { _ in fixture.run(status: .completed, response: fixture.validJSON) },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        await coordinator.prepare(machineID: "synthetic-machine", transport: transport)

        #expect(coordinator.selectedModel == nil)
        #expect(fixture.defaults.string(forKey: "herdr.responseBrief.model.v1") == nil)
    }

    @Test("Corrupt persistence blocks dispatch visibly")
    func corruptPersistenceBlocksDispatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("corrupt".utf8).write(to: fixture.folder.appending(path: "cache.json"))
        let coordinator = fixture.coordinator()
        let source = fixture.source(responseID: "answer-corrupt", text: "line one\nline two")
        var starts = 0
        let transport = fixture.transport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: fixture.validJSON)
            },
            fetch: { _ in fixture.run(status: .completed, response: fixture.validJSON) }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)

        #expect(starts == 0)
        guard case let .failed(message) = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected persistence failure")
            return
        }
        #expect(message.contains("blocked"))
    }

    @Test("Finite deadline cancels the owned remote run")
    func deadlineCancelsRemoteRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.generationTimeout = .milliseconds(5)
        coordinator.runPollDelay = .seconds(100)
        let source = fixture.source(responseID: "answer-timeout", text: "line one\nline two")
        var cancellations = 0
        let transport = ResponseBriefTransport(
            capabilities: { _ in AssistantCapabilities(profiles: ["response-brief-v1"]) },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [fixture.briefModel], defaultModel: nil) },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, _ in fixture.run(status: .queued, response: nil) },
            fetch: { _, _ in fixture.run(status: .queued, response: nil) },
            cancel: { _, _ in
                cancellations += 1
                return fixture.run(status: .cancelled, response: nil)
            }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(cancellations == 1)
        guard case let .failed(message) = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected deadline failure")
            return
        }
        #expect(message.contains("two-minute deadline"))
        #expect(message.contains("may still be settling"))
        #expect(!message.contains("was cancelled"))
    }

    @Test("A terminal malformed result is not automatically resubmitted")
    func terminalFailureRequiresExplicitAction() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let source = fixture.source(responseID: "answer-invalid", text: "line one\nline two")
        var starts = 0
        let transport = fixture.transport(
            start: { _ in
                starts += 1
                return fixture.run(status: .completed, response: #"{"version":2}"#)
            },
            fetch: { _ in fixture.run(status: .completed, response: #"{"version":2}"#) }
        )

        coordinator.enable(source.chat)
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()
        await coordinator.observe(source, transport: transport)
        await coordinator.waitForIdleForTesting()

        #expect(starts == 1)
        guard case .failed = coordinator.state(for: source.chat).phase else {
            Issue.record("Expected malformed-result failure")
            return
        }
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
    return condition()
}

@MainActor
private final class Fixture {
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
    let validJSON = #"{"version":1,"title":"Synthetic result","summary":"The answer has two lines.","points":[{"text":"Read both lines.","startLine":1,"endLine":2}],"details":[{"label":"Read exact answer","kind":"detail","startLine":1,"endLine":2}]}"#

    init() throws {
        let newFolder = FileManager.default.temporaryDirectory.appending(path: "response-brief-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let newSuiteName = "response-brief-tests-\(UUID().uuidString)"
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

    func source(responseID: String, text: String) -> ResponseBriefSource {
        ResponseBriefSource(
            chat: .init(machineID: "synthetic-machine", paneID: "w1:p2", sessionID: "synthetic-session"),
            responseID: responseID,
            text: text,
            currentUserText: "Current question",
            previousUserText: "Previous question",
            previousAssistantText: "Previous answer"
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

    func generationID(for source: ResponseBriefSource, model: String?, thinkingLevel: String?) -> String {
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

    func transport(
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

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
