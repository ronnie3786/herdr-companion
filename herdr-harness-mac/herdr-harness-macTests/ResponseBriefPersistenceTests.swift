import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief persistence", .serialized)
struct ResponseBriefPersistenceTests {
    @Test("Corrupt cache is reported instead of treated as empty")
    func corruptCacheBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        try Data("not-json".utf8).write(to: url)
        let persistence = ResponseBriefPersistence(url: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await persistence.snapshot()
        }
    }

    @Test("Valid JSON without baseline ownership arrays is rejected")
    func emptyObjectBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        try Data("{}".utf8).write(to: url)
        let persistence = ResponseBriefPersistence(url: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await persistence.snapshot()
        }
    }

    @Test("Predecessor cache requests with nil model and thinking level remain valid")
    func predecessorReceiptLoads() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let receipt = try makeReceipt(id: "predecessor-attempt")
        try writeSnapshot(receipts: [receipt], to: url)
        let persistence = ResponseBriefPersistence(url: url)

        let state = try await persistence.snapshot()
        #expect(state.receipts.map(\.id) == [receipt.id])
        #expect(state.receipts.first?.request.model == nil)
        #expect(state.receipts.first?.request.thinkingLevel == nil)
        #expect(state.attemptedGenerationIDs.isEmpty)
        #expect(state.responseCursorByChatID.isEmpty)
    }

    @Test("Duplicate receipt identifiers are rejected before coordinator restoration")
    func duplicateReceiptBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let receipt = try makeReceipt(id: "duplicate-attempt")
        try writeSnapshot(receipts: [receipt, receipt], to: url)
        let persistence = ResponseBriefPersistence(url: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await persistence.snapshot()
        }
    }

    @Test(
        "Cached requests cannot change the fixed response brief capability contract",
        arguments: InvalidRequestMutation.allCases
    )
    func alteredCachedRequestBlocksLoad(_ mutation: InvalidRequestMutation) async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let receipt = try makeReceipt(id: "altered-attempt", mutation: mutation)
        try writeSnapshot(receipts: [receipt], to: url)
        let persistence = ResponseBriefPersistence(url: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await persistence.snapshot()
        }
    }

    @Test("A failed disk save rolls memory back")
    func saveRollback() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let persistence = ResponseBriefPersistence(url: blocker.appending(path: "cache.json"))
        let receipt = try makeReceipt(id: "attempt-one")

        var didFail = false
        do {
            try await persistence.saveReceipt(receipt)
        } catch {
            didFail = true
        }
        #expect(didFail)
        let state = try await persistence.snapshot()
        #expect(state.receipts.isEmpty)
        #expect(!state.attemptedGenerationIDs.contains(receipt.id))
    }

    @Test("Unresolved receipts are refused rather than evicted")
    func unresolvedReceiptsAreNeverEvicted() async throws {
        let persistence = ResponseBriefPersistence(
            maximumRecords: 1,
            maximumOutstandingReceipts: 1,
            maximumBytes: 1_000_000,
            inMemory: true
        )
        let first = try makeReceipt(id: "attempt-one")
        let second = try makeReceipt(id: "attempt-two")
        try await persistence.saveReceipt(first)

        await #expect(throws: ResponseBriefPersistenceError.tooManyOutstandingRuns) {
            try await persistence.saveReceipt(second)
        }
        let state = try await persistence.snapshot()
        #expect(state.receipts.map(\.id) == [first.id])
    }

    @Test("Cache clear preserves dedupe and source baseline")
    func clearPreservesLedgerAndCursor() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        var receipt = try makeReceipt(id: "attempt-one")
        try await persistence.advanceCursor(chatID: receipt.source.chat.id, responseID: receipt.source.responseID)
        try await persistence.saveReceipt(receipt)

        await #expect(throws: ResponseBriefPersistenceError.outstandingRunsPreventClear) {
            try await persistence.clearCachedRecords()
        }

        receipt.status = .settled
        try await persistence.saveReceipt(receipt)
        try await persistence.clearCachedRecords()
        let state = try await persistence.snapshot()
        #expect(state.records.isEmpty)
        #expect(state.receipts.isEmpty)
        #expect(state.attemptedGenerationIDs.contains(receipt.id))
        #expect(state.responseCursorByChatID[receipt.source.chat.id] == receipt.source.responseID)
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "response-brief-persistence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeReceipt(
        id: String,
        mutation: InvalidRequestMutation? = nil
    ) throws -> ResponseBriefPersistence.Receipt {
        let source = ResponseBriefSource(
            chat: .init(machineID: "synthetic-machine", paneID: "w1:p1", sessionID: "synthetic-session"),
            responseID: id,
            text: "Synthetic answer",
            currentUserText: "Synthetic question",
            previousUserText: nil,
            previousAssistantText: nil
        )
        var request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: nil,
            thinkingLevel: nil,
            clientRequestID: "request-\(id)"
        )
        switch mutation {
        case .profile:
            request.profile = "hud-action-v1"
        case .mode:
            request.mode = "action"
        case .parent:
            request.parentSessionId = "different-session"
        case .source:
            request.context.source.feature = "hud.generic-action"
        case .requiredText:
            request.context.items[0].text = "Different answer"
        case nil:
            break
        }
        return ResponseBriefPersistence.Receipt(
            id: id,
            source: source,
            request: request,
            runID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func writeSnapshot(
        receipts: [ResponseBriefPersistence.Receipt],
        to url: URL
    ) throws {
        let snapshot = StoredSnapshot(records: [], receipts: receipts)
        try JSONEncoder().encode(snapshot).write(to: url)
    }
}

enum InvalidRequestMutation: CaseIterable, Sendable {
    case profile
    case mode
    case parent
    case source
    case requiredText
}

private struct StoredSnapshot: Encodable {
    let records: [ResponseBriefPersistence.Record]
    let receipts: [ResponseBriefPersistence.Receipt]
}
