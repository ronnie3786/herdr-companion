import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD persistence")
@MainActor
struct HerdrHudPersistenceTests {
    @Test("A thread and its transcript round-trip through the persistence file")
    func roundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let session = makeSession(fileURL: fileURL)
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "root-run",
            lastRunID: "last-run",
            turnCount: 2
        )
        let exchanges = [
            exchange(id: "first", prompt: "First prompt", response: "First response"),
            exchange(
                id: "second",
                prompt: "Second prompt",
                response: "Second response",
                modelLabel: "custom/model",
                steps: [step(id: "tool-1"), step(id: "tool-2")]
            )
        ]
        session.seedThreadForTesting(thread)
        session.seedExchangesForTesting(exchanges)

        try HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges).save(to: fileURL)

        let restored = makeSession(fileURL: fileURL)
        await restored.waitForPersistenceRestoreForTesting()

        #expect(restored.thread == thread)
        #expect(restored.exchanges.count == 2)
        let second = try #require(restored.exchanges.last)
        #expect(second.prompt == "Second prompt")
        #expect(second.response == "Second response")
        #expect(second.status == .completed)
        #expect(second.modelLabel == "custom/model")
        #expect(second.steps.count == 2)
        #expect(second.workingFolderPath == HerdrHudWorkingFolder.homePath)
    }

    @Test("A custom working folder survives HUD persistence")
    func workingFolderRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let folder = "/synthetic/remote/project"
        let session = makeSession(fileURL: fileURL)
        session.seedExchangesForTesting([
            exchange(id: "custom", prompt: "Custom folder", response: "Done", workingFolderPath: folder)
        ])
        try HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges).save(to: fileURL)

        let restored = makeSession(fileURL: fileURL)
        await restored.waitForPersistenceRestoreForTesting()

        #expect(restored.exchanges.first?.workingFolderPath == folder)
        #expect(restored.selectedWorkingFolder.path == folder)
    }

    @Test("A missing persistence file restores as an empty HUD")
    func missingFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession(fileURL: directory.appendingPathComponent("missing.json"))

        await session.waitForPersistenceRestoreForTesting()

        #expect(session.thread == nil)
        #expect(session.exchanges.isEmpty)
    }

    @Test("A corrupt persistence file restores as an empty HUD")
    func corruptFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        try Data("this is not JSON".utf8).write(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.thread == nil)
        #expect(session.exchanges.isEmpty)
    }

    @Test("An unknown persistence schema version restores as an empty HUD")
    func unknownVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let snapshot = HerdrHudPersistenceSnapshot(version: 999, thread: nil, exchanges: [])
        try snapshot.save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.thread == nil)
        #expect(session.exchanges.isEmpty)
    }

    @Test("A non-terminal persisted exchange becomes a failed interruption")
    func nonTerminalExchangeIsFailedAfterRestore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        try HerdrHudPersistenceSnapshot(
            thread: nil,
            exchanges: [exchange(id: "running", prompt: "Waiting", status: .running)]
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        let restored = try #require(session.exchanges.first)
        #expect(restored.status == .failed)
        #expect(restored.error == "Interrupted by app restart")
        #expect(!session.isRunning)
    }

    @Test("Disk persistence keeps exactly the newest ten exchanges")
    func diskExchangeCap() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let session = makeSession(fileURL: fileURL)
        session.seedExchangesForTesting(
            (0..<30).map { index in
                exchange(id: "run-\(index)", prompt: "Prompt \(index)", response: "Response \(index)")
            }
        )

        try HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges).save(to: fileURL)

        let snapshot = try #require(HerdrHudPersistenceSnapshot.load(from: fileURL))
        #expect(snapshot.exchanges.count == 10)
        #expect(snapshot.exchanges.map(\.id) == (20..<30).map { "run-\($0)" })
        #expect(snapshot.exchanges.map(\.prompt) == (20..<30).map { "Prompt \($0)" })
    }

    @Test("An oversized response is truncated with the persistence marker")
    func oversizedResponseIsTruncated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let response = String(repeating: "x", count: HerdrHudPersistenceSnapshot.maximumResponseBytes + 128)
        let session = makeSession(fileURL: fileURL)
        session.seedExchangesForTesting([exchange(id: "large", prompt: "Large", response: response)])

        try HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges).save(to: fileURL)

        let restored = makeSession(fileURL: fileURL)
        await restored.waitForPersistenceRestoreForTesting()
        let persistedResponse = try #require(restored.exchanges.first?.response)
        #expect(persistedResponse.utf8.count <= HerdrHudPersistenceSnapshot.maximumResponseBytes)
        #expect(persistedResponse.utf8.count < response.utf8.count)
        #expect(persistedResponse.contains(HerdrHudPersistenceSnapshot.truncatedResponseMarker))
    }

    @Test("Clearing the HUD removes its persistence file")
    func clearRemovesFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let session = makeSession(fileURL: fileURL)
        session.seedThreadForTesting(
            HerdrHudSession.HerdrHudThread(
                machineID: "demo1",
                rootRunID: "root-run",
                lastRunID: "last-run",
                turnCount: 1
            )
        )
        session.seedExchangesForTesting([exchange(id: "root-run", prompt: "Clear", response: "Done")])
        try HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges).save(to: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        await session.clear(model: makeDemoModel())

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("A restored thread continues from its last run ID")
    func restoredThreadContinuesFromLastRunID() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "root-run",
            lastRunID: "last-run",
            turnCount: 3
        )
        try HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: [exchange(id: "last-run", prompt: "Earlier", response: "Earlier response")]
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()
        session.draft = "Follow-up"
        await session.submit(model: makeDemoModel())

        #expect(session.lastHeadlessRunForTesting?.threadRootRunId == thread.lastRunID)
    }

    @Test("A chat metadata aggregate round-trips with the persistence snapshot")
    func chatMetadataRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "root-run",
            lastRunID: "run-2",
            turnCount: 2
        )
        var metadata = HerdrHudChatMetadataAccumulator()
        metadata.reconcile(
            machineID: "demo1",
            rootRunID: "root-run",
            expectedTurnCount: 2,
            samples: [
                .init(id: "root-run", costUSD: 0.40, modelName: "Sonnet 4.5"),
                .init(id: "run-2", costUSD: 1.00, modelName: "Opus 4.5"),
            ]
        )
        try HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: [exchange(id: "run-2", prompt: "Second", response: "Done")],
            chatMetadata: metadata
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.chatMetadata.observedRunCount == 2)
        #expect(session.bubbleMetadata.cost == "$1.40")
        #expect(session.bubbleMetadata.modelName == "Opus 4.5")
    }

    @Test("A truncated legacy cache leaves the cost unknown until history proves coverage")
    func truncatedLegacyCacheKeepsCostUnknown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "root-run",
            lastRunID: "run-12",
            turnCount: 12
        )
        let exchanges = (3..<13).map { index in
            exchange(id: "run-\(index)", prompt: "Prompt \(index)", response: "Done")
        }
        try HerdrHudPersistenceSnapshot(thread: thread, exchanges: exchanges).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.chatMetadata.observedRunCount == 10)
        #expect(session.bubbleMetadata.cost == nil)
    }

    @Test("A complete legacy cache rebuilds its cumulative cost")
    func completeLegacyCacheRebuildsCost() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "run-1",
            lastRunID: "run-2",
            turnCount: 2
        )
        try HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: [
                exchange(id: "run-1", prompt: "First", response: "Done", modelLabel: "Sonnet 4.5"),
                exchange(id: "run-2", prompt: "Second", response: "Done", modelLabel: "Opus 4.5"),
            ]
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.bubbleMetadata.cost == "$2.46")
        #expect(session.bubbleMetadata.modelName == "Opus 4.5")
    }

    @Test("A legacy cache interrupted mid-run leaves the cost unknown")
    func interruptedLegacyCacheKeepsCostUnknown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "run-1",
            lastRunID: "run-1",
            turnCount: 1
        )
        try HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: [exchange(id: "run-1", prompt: "Interrupted", status: .running)]
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.exchanges.first?.status == .failed)
        #expect(!session.chatMetadata.hasEstablishedCoverage)
        #expect(session.bubbleMetadata.cost == nil)
    }

    @Test("Persisted metadata for a different conversation is not trusted")
    func persistedMetadataForAnotherConversationIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hud-thread.json")
        let thread = HerdrHudSession.HerdrHudThread(
            machineID: "demo1",
            rootRunID: "root-run",
            lastRunID: "run-2",
            turnCount: 2
        )
        var metadata = HerdrHudChatMetadataAccumulator()
        metadata.reconcile(
            machineID: "other-machine",
            rootRunID: "other-root",
            expectedTurnCount: 1,
            samples: [.init(id: "other-run", costUSD: 9.99, modelName: "Other Model")]
        )
        try HerdrHudPersistenceSnapshot(
            thread: thread,
            exchanges: [exchange(id: "run-2", prompt: "Second", response: "Done")],
            chatMetadata: metadata
        ).save(to: fileURL)

        let session = makeSession(fileURL: fileURL)
        await session.waitForPersistenceRestoreForTesting()

        #expect(session.chatMetadata.observedRunCount == 1)
        #expect(session.bubbleMetadata.cost == nil)
        #expect(session.bubbleMetadata.modelName == nil)
    }

    @Test("More than twenty live turns keep their aggregate after the transcript cap")
    func moreThanTwentyLiveTurnsKeepAggregate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession(fileURL: directory.appendingPathComponent("hud-thread.json"))
        let model = makeDemoModel()

        for index in 0...21 {
            session.draft = "prompt \(index)"
            await session.submit(model: model)
        }

        #expect(session.exchanges.count == 20)
        #expect(session.chatMetadata.observedRunCount == 22)
        #expect(session.bubbleMetadata.cost == "$0.00")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrHudPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSession(fileURL: URL) -> HerdrHudSession {
        let suiteName = "HerdrHudPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HerdrHudSession(userDefaults: defaults, persistenceURL: fileURL)
    }

    private func makeDemoModel() -> HerdrAppModel {
        let suiteName = "HerdrHudPersistenceTests.model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
    }

    private func exchange(
        id: String,
        prompt: String,
        response: String? = nil,
        status: HeadlessAgentRunStatus = .completed,
        modelLabel: String = "default",
        steps: [HerdrHudStep] = [],
        workingFolderPath: String = HerdrHudWorkingFolder.homePath
    ) -> HerdrHudExchange {
        HerdrHudExchange(
            id: id,
            machineID: "demo1",
            prompt: prompt,
            sentPrompt: prompt,
            response: response,
            error: nil,
            status: status,
            costUSD: 1.23,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            promotedPaneID: nil,
            attachmentFilenames: ["image.png"],
            workingFolderPath: workingFolderPath,
            modelLabel: modelLabel,
            steps: steps,
            stepsTruncated: true
        )
    }

    private func step(id: String) -> HerdrHudStep {
        HerdrHudStep(
            id: id,
            title: "Command",
            detail: "git status",
            symbol: "terminal",
            isFailure: false,
            isRunning: false
        )
    }
}
