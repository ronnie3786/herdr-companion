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

    @Test("Legacy records decode without captured length metadata")
    func legacyRecordsDecodeWithoutCapturedLengthMetadata() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let record = ResponseBriefPersistence.Record(
            id: "legacy-record",
            source: makeSource(responseID: "legacy-record"),
            brief: ResponseBrief(version: 1, title: "Synthetic", summary: "Ready.", points: [], details: []),
            model: nil,
            thinkingLevel: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try writeSnapshot(records: [record], to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("responseBriefLength"))
        let state = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(state.records.count == 1)
        #expect(state.records.first?.responseBriefLength == nil)
        #expect(state.records.first?.responseBriefLengthPolicyVersion == nil)
        #expect(state.records.first?.capturedConcisionPolicy == nil)
        #expect(state.baselineAnchors.isEmpty)
        #expect(state.verifiedAliases.isEmpty)
        #expect(state.pendingRegenerations.isEmpty)
    }

    @Test("Captured length metadata round-trips and validates against its own policy")
    func capturedLengthRoundTrip() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let sourceText = String(repeating: "z", count: 3_000)
        let record = makeCapturedRecord(
            id: "captured-long",
            length: .long,
            summary: String(repeating: "a", count: 700),
            sourceText: sourceText
        )
        try await ResponseBriefPersistence(url: url).saveRecord(record)

        let state = try await ResponseBriefPersistence(url: url).snapshot()
        let stored = try #require(state.records.first)
        #expect(stored.responseBriefLength == .long)
        #expect(stored.responseBriefLengthPolicyVersion == ResponseBriefLength.policyVersion)
        #expect(stored.capturedConcisionPolicy != nil)
        #expect(stored.brief.conformsToConcisionPolicy(source: sourceText, length: .long))
    }

    @Test("A record whose brief violates its captured policy blocks restoration")
    func recordViolatingCapturedPolicyBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let record = makeCapturedRecord(
            id: "tampered-long",
            length: .long,
            summary: String(repeating: "a", count: 721),
            sourceText: String(repeating: "z", count: 3_000)
        )
        try writeSnapshot(records: [record], to: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await ResponseBriefPersistence(url: url).snapshot()
        }
    }

    @Test("A record captured under an unknown policy version stays readable")
    func unknownPolicyVersionRecordStaysReadable() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        var record = makeCapturedRecord(
            id: "future-policy",
            length: .long,
            summary: String(repeating: "a", count: 721),
            sourceText: String(repeating: "z", count: 3_000)
        )
        record.responseBriefLengthPolicyVersion = 99
        try writeSnapshot(records: [record], to: url)

        let state = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(state.records.count == 1)
        #expect(state.records.first?.responseBriefLengthPolicyVersion == 99)
    }

    @Test("Identity anchors, verified aliases, and regeneration intents survive relaunch")
    func durableIdentityStateSurvivesRelaunch() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let persistence = ResponseBriefPersistence(url: url)
        let source = makeSource(responseID: "entry-a1")
        let chatID = source.chat.id
        let evidence = ResponseBriefIdentityEvidence(
            responseText: source.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_100),
            userText: "Synthetic question",
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await persistence.recordBaselineAnchor(
            chatID: chatID,
            responseID: "entry-a1",
            identity: evidence,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        try await persistence.recordVerifiedAlias(
            chatID: chatID,
            aliasID: "live:synthetic:1",
            canonicalID: "entry-a1",
            identity: evidence,
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_201)
        )
        try await persistence.savePendingRegeneration(.init(
            chatID: chatID,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_202)
        ))

        let state = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(state.baselineAnchors[chatID]?.responseID == "entry-a1")
        #expect(state.baselineAnchors[chatID]?.identity == evidence)
        #expect(state.verifiedAliases[chatID]?.map(\.aliasID) == ["live:synthetic:1"])
        #expect(state.verifiedAliases[chatID]?.first?.canonicalID == "entry-a1")
        #expect(state.pendingRegenerations[chatID]?.length == .medium)
        #expect(state.pendingRegenerations[chatID]?.source.responseID == "entry-a1")
    }

    @Test("A combined cursor and anchor advance persists both together")
    func combinedCursorAndAnchorAdvance() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-a1")
        let evidence = ResponseBriefIdentityEvidence(
            responseText: source.text,
            responseTimestamp: Date(timeIntervalSince1970: 1_800_000_100),
            userText: "Synthetic question",
            userTimestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await persistence.advanceCursor(
            chatID: source.chat.id,
            responseID: "entry-a1",
            anchorIdentity: evidence,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )

        let state = try await persistence.snapshot()
        #expect(state.responseCursorByChatID[source.chat.id] == "entry-a1")
        #expect(state.baselineAnchors[source.chat.id]?.responseID == "entry-a1")
        #expect(state.baselineAnchors[source.chat.id]?.identity == evidence)
    }

    @Test("Regeneration intents coalesce to the latest selection for a chat")
    func regenerationIntentCoalesces() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-a1")
        for (index, length) in [ResponseBriefLength.minimal, .medium, .long].enumerated() {
            try await persistence.savePendingRegeneration(.init(
                chatID: source.chat.id,
                source: source,
                length: length,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            ))
        }

        let state = try await persistence.snapshot()
        #expect(state.pendingRegenerations.count == 1)
        #expect(state.pendingRegenerations[source.chat.id]?.length == .long)
    }

    @Test("A recovery intent saves atomically with its baseline and coalesces")
    func recoveryIntentSavesWithBaseline() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-recovery")
        let first = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .minimal,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )

        try await persistence.saveRecoveryIntent(
            first,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_501)
        )

        var state = try await persistence.snapshot()
        #expect(state.responseCursorByChatID[source.chat.id] == source.responseID)
        #expect(state.baselineAnchors[source.chat.id]?.responseID == source.responseID)
        #expect(state.pendingRegenerations[source.chat.id]?.createdAt == first.createdAt)
        #expect(state.pendingRegenerations[source.chat.id]?.length == .minimal)

        let second = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600)
        )
        try await persistence.saveRecoveryIntent(
            second,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_601)
        )

        state = try await persistence.snapshot()
        #expect(state.pendingRegenerations.count == 1)
        #expect(state.pendingRegenerations[source.chat.id]?.length == .long)
        #expect(state.pendingRegenerations[source.chat.id]?.createdAt == second.createdAt)
    }

    @Test("A failed recovery-intent save rolls the baseline and intent back")
    func recoveryIntentSaveRollsBack() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let persistence = ResponseBriefPersistence(url: blocker.appending(path: "cache.json"))
        let source = makeSource(responseID: "entry-recovery-rollback")

        var didFail = false
        do {
            try await persistence.saveRecoveryIntent(
                .init(
                    chatID: source.chat.id,
                    source: source,
                    length: .medium,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_500)
                ),
                recordedAt: Date(timeIntervalSince1970: 1_800_000_501)
            )
        } catch {
            didFail = true
        }

        #expect(didFail)
        let state = try await persistence.snapshot()
        #expect(state.pendingRegenerations.isEmpty)
        #expect(state.responseCursorByChatID[source.chat.id] == nil)
        #expect(state.baselineAnchors[source.chat.id] == nil)
    }

    @Test("A replacement receipt commits only while its captured intent is current")
    func replacementReceiptCommitRevalidatesIntent() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-replacement")
        let mediumIntent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )
        try await persistence.savePendingRegeneration(mediumIntent)
        let request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: nil,
            thinkingLevel: nil,
            clientRequestID: "replacement-receipt",
            length: .medium
        )
        let receipt = ResponseBriefPersistence.Receipt(
            id: "replacement-receipt",
            source: source,
            request: request,
            runID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_502)
        )

        // A newer selection supersedes the intent while the earlier request
        // was still in asynchronous preflight.
        let longIntent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600)
        )
        try await persistence.savePendingRegeneration(longIntent)

        let supersededCommit = try await persistence.commitReplacementReceipt(
            receipt,
            expecting: mediumIntent.replacementKey,
            revision: mediumIntent.revision
        )
        #expect(!supersededCommit)
        var state = try await persistence.snapshot()
        #expect(state.receipts.isEmpty)
        #expect(!state.attemptedGenerationIDs.contains(receipt.id))
        #expect(state.pendingRegenerations[source.chat.id]?.length == .long)

        let currentCommit = try await persistence.commitReplacementReceipt(
            receipt,
            expecting: longIntent.replacementKey,
            revision: longIntent.revision
        )
        #expect(currentCommit)
        state = try await persistence.snapshot()
        #expect(state.receipts.map(\.id) == [receipt.id])
        #expect(state.pendingRegenerations.isEmpty)
        #expect(state.attemptedGenerationIDs.contains(receipt.id))
    }

    @Test("A superseded cleanup never removes a newer intent")
    func supersededCleanupKeepsNewerIntent() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-cleanup")
        let mediumIntent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )
        try await persistence.savePendingRegeneration(mediumIntent)
        let longIntent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600)
        )
        try await persistence.savePendingRegeneration(longIntent)

        try await persistence.removePendingRegeneration(
            chatID: source.chat.id,
            expectingKey: mediumIntent.replacementKey
        )

        var state = try await persistence.snapshot()
        #expect(state.pendingRegenerations[source.chat.id]?.length == .long)

        try await persistence.removePendingRegeneration(
            chatID: source.chat.id,
            expectingKey: longIntent.replacementKey
        )
        state = try await persistence.snapshot()
        #expect(state.pendingRegenerations.isEmpty)
    }

    @Test("A delayed stale intent write cannot replace the newest intent")
    func staleIntentWritesAreRejectedAtomically() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-stale-write")
        let chatID = source.chat.id
        let medium = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500),
            revision: 1
        )
        let long = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600),
            revision: 2
        )

        #expect(try await persistence.savePendingRegeneration(medium))
        #expect(try await persistence.savePendingRegeneration(long))
        // The delayed Medium write lands after Long and must be rejected inside
        // the same atomic mutation instead of replacing it.
        #expect(try await persistence.savePendingRegeneration(medium) == false)
        var state = try await persistence.snapshot()
        #expect(state.pendingRegenerations[chatID]?.length == .long)
        #expect(state.regenerationRevisions[chatID] == 2)

        try await persistence.cancelPendingRegeneration(chatID: chatID, revision: 2)
        state = try await persistence.snapshot()
        #expect(state.pendingRegenerations.isEmpty)
        #expect(state.regenerationRevisions[chatID] == 2)

        // The cancellation tombstone keeps rejecting older writes while a
        // genuinely newer selection still lands.
        #expect(try await persistence.savePendingRegeneration(medium) == false)
        let newer = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .minimal,
            createdAt: Date(timeIntervalSince1970: 1_800_000_700),
            revision: 3
        )
        #expect(try await persistence.savePendingRegeneration(newer))
        state = try await persistence.snapshot()
        #expect(state.pendingRegenerations[chatID]?.length == .minimal)
        #expect(state.pendingRegenerations[chatID]?.revision == 3)
    }

    @Test("A stale recovery intent is rejected without touching its baseline")
    func staleRecoveryIntentIsRejected() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let newerSource = makeSource(responseID: "entry-recovery-newer")
        let olderSource = makeSource(responseID: "entry-recovery-older")
        let chatID = newerSource.chat.id
        let current = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: newerSource,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600),
            revision: 2
        )
        #expect(try await persistence.saveRecoveryIntent(
            current,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_601)
        ))

        let stale = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: olderSource,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500),
            revision: 1
        )
        #expect(try await persistence.saveRecoveryIntent(
            stale,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_602)
        ) == false)

        let state = try await persistence.snapshot()
        #expect(state.pendingRegenerations[chatID]?.source.responseID == newerSource.responseID)
        #expect(state.pendingRegenerations[chatID]?.length == .long)
        #expect(state.responseCursorByChatID[chatID] == newerSource.responseID)
        #expect(state.baselineAnchors[chatID]?.responseID == newerSource.responseID)
    }

    @Test("A superseded recovery cursor move is rejected after a newer selection is admitted")
    func supersededRecoveryCursorMoveIsRejected() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-recovery-cursor")
        let chatID = source.chat.id
        // The confirmed recovery reserved revision 1 before its snapshot fetch
        // suspended, and a newer length selection was durably admitted while
        // that fetch was in flight.
        #expect(try await persistence.savePendingRegeneration(.init(
            chatID: chatID,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600),
            revision: 2
        )))

        let moved = try await persistence.advanceCursor(
            chatID: chatID,
            responseID: source.responseID,
            anchorIdentity: nil,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_601),
            expectingRevision: 1
        )
        #expect(!moved)
        let state = try await persistence.snapshot()
        #expect(state.responseCursorByChatID[chatID] == nil)
        #expect(state.baselineAnchors[chatID] == nil)
        #expect(state.pendingRegenerations[chatID]?.length == .long)

        // The current revision can still establish the baseline.
        let currentMove = try await persistence.advanceCursor(
            chatID: chatID,
            responseID: source.responseID,
            anchorIdentity: nil,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_602),
            expectingRevision: 2
        )
        #expect(currentMove)
        let updated = try await persistence.snapshot()
        #expect(updated.responseCursorByChatID[chatID] == source.responseID)
        #expect(updated.baselineAnchors[chatID]?.responseID == source.responseID)
    }

    @Test("A rejected stale write cannot survive immediate restoration and a tombstone survives relaunch")
    func staleIntentRejectionSurvivesRestoration() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let persistence = ResponseBriefPersistence(url: url)
        let source = makeSource(responseID: "entry-stale-restore")
        let chatID = source.chat.id
        let long = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_600),
            revision: 2
        )
        #expect(try await persistence.savePendingRegeneration(long))
        let staleMedium = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500),
            revision: 1
        )
        // The stale write is rejected before any coordinator cleanup can run.
        #expect(try await persistence.savePendingRegeneration(staleMedium) == false)

        // Restore immediately from disk, exactly as a relaunch would.
        let restored = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(restored.pendingRegenerations[chatID]?.length == .long)
        #expect(restored.regenerationRevisions[chatID] == 2)

        try await persistence.cancelPendingRegeneration(chatID: chatID, revision: 2)
        let cancelled = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(cancelled.pendingRegenerations.isEmpty)
        #expect(cancelled.regenerationRevisions[chatID] == 2)

        // The tombstone is durable: an older write stays rejected even after
        // another relaunch, and a newer selection can still be resumed.
        #expect(try await persistence.savePendingRegeneration(staleMedium) == false)
        #expect(try await ResponseBriefPersistence(url: url).snapshot().pendingRegenerations.isEmpty)
        let newer = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_700),
            revision: 3
        )
        #expect(try await persistence.savePendingRegeneration(newer))
        let resumed = try await ResponseBriefPersistence(url: url).snapshot()
        #expect(resumed.pendingRegenerations[chatID]?.length == .medium)
        #expect(resumed.pendingRegenerations[chatID]?.revision == 3)
    }

    @Test("Legacy intent JSON without a revision decodes as unordered")
    func legacyIntentWithoutRevisionDecodes() throws {
        let intent = ResponseBriefPersistence.PendingRegeneration(
            chatID: "synthetic-chat",
            source: makeSource(responseID: "entry-a1"),
            length: .medium,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any]
        )
        object.removeValue(forKey: "revision")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            ResponseBriefPersistence.PendingRegeneration.self,
            from: data
        )
        #expect(decoded.revision == 0)
        #expect(decoded == intent)
    }

    @Test("An intent revision ahead of its durable watermark blocks restoration")
    func intentRevisionAheadOfWatermarkBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let source = makeSource(responseID: "entry-a1")
        let chatID = source.chat.id
        let intent = ResponseBriefPersistence.PendingRegeneration(
            chatID: chatID,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500),
            revision: 3
        )
        try writeSnapshot(
            pendingRegenerations: [chatID: intent],
            regenerationRevisions: [chatID: 1],
            to: url
        )

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await ResponseBriefPersistence(url: url).snapshot()
        }
    }

    @Test("Verified aliases are bounded per chat with the oldest evicted")
    func verifiedAliasesAreBounded() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let chatID = "synthetic-chat"
        for index in 0..<12 {
            try await persistence.recordVerifiedAlias(
                chatID: chatID,
                aliasID: "alias-\(index)",
                canonicalID: "entry-a1",
                identity: nil,
                verifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }

        let aliases = try await persistence.snapshot().verifiedAliases[chatID]
        #expect(aliases?.count == 8)
        #expect(aliases?.map(\.aliasID) == (4..<12).map { "alias-\($0)" })
    }

    @Test("Baseline anchors are bounded and evict the oldest chat")
    func baselineAnchorsAreBounded() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        for index in 0..<41 {
            try await persistence.recordBaselineAnchor(
                chatID: "chat-\(index)",
                responseID: "response-\(index)",
                identity: nil,
                recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }

        let anchors = try await persistence.snapshot().baselineAnchors
        #expect(anchors.count == 40)
        #expect(anchors["chat-0"] == nil)
        #expect(anchors["chat-40"] != nil)
    }

    @Test("Pending regeneration intents are bounded across chats")
    func pendingRegenerationsAreBounded() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-a1")
        for index in 0..<40 {
            try await persistence.savePendingRegeneration(.init(
                chatID: "chat-\(index)",
                source: source,
                length: .minimal,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        }

        await #expect(throws: ResponseBriefPersistenceError.tooManyPendingRegenerations) {
            try await persistence.savePendingRegeneration(.init(
                chatID: "chat-overflow",
                source: source,
                length: .minimal,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        }
    }

    @Test(
        "Tampered relationship metadata blocks restoration",
        arguments: TamperedIdentityState.allCases
    )
    func tamperedRelationshipMetadataBlocksLoad(_ state: TamperedIdentityState) async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let chatID = "synthetic-chat"
        let invalidEvidence = try JSONDecoder().decode(
            ResponseBriefIdentityEvidence.self,
            from: Data(#"{"responseTextHash":"not-a-hash"}"#.utf8)
        )
        var anchors: [String: ResponseBriefPersistence.BaselineAnchor] = [:]
        var aliases: [String: [ResponseBriefPersistence.VerifiedAlias]] = [:]
        var intents: [String: ResponseBriefPersistence.PendingRegeneration] = [:]
        switch state {
        case .aliasMatchesCanonical:
            aliases[chatID] = [.init(
                aliasID: "same",
                canonicalID: "same",
                identity: nil,
                verifiedAt: Date(timeIntervalSince1970: 1)
            )]
        case .invalidEvidenceHash:
            anchors[chatID] = .init(
                chatID: chatID,
                responseID: "entry-a1",
                identity: invalidEvidence,
                recordedAt: Date(timeIntervalSince1970: 1)
            )
        case .anchorChatMismatch:
            anchors[chatID] = .init(
                chatID: "other-chat",
                responseID: "entry-a1",
                identity: nil,
                recordedAt: Date(timeIntervalSince1970: 1)
            )
        case .intentChatMismatch:
            intents[chatID] = .init(
                chatID: "other-chat",
                source: makeSource(responseID: "entry-a1"),
                length: .medium,
                createdAt: Date(timeIntervalSince1970: 1)
            )
        }
        try writeSnapshot(
            baselineAnchors: anchors,
            verifiedAliases: aliases,
            pendingRegenerations: intents,
            to: url
        )

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await ResponseBriefPersistence(url: url).snapshot()
        }
    }

    @Test("Legacy receipts keep replaying the exact legacy request")
    func legacyReceiptReplaysLegacyRequest() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let receipt = try makeReceipt(id: "legacy-attempt")
        try writeSnapshot(receipts: [receipt], to: url)

        let state = try await ResponseBriefPersistence(url: url).snapshot()
        let stored = try #require(state.receipts.first)
        #expect(stored.request.responseBriefLength == nil)
        #expect(stored.request.prompt == ResponseBriefRequestBuilder.prompt)
        #expect(stored.request.prompt.contains("140 words"))
    }

    @Test("Length-selected receipts validate their own prompt and selection")
    func lengthSelectedReceiptValidates() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let receipt = try makeReceipt(id: "long-attempt", length: .long)
        try writeSnapshot(receipts: [receipt], to: url)

        let state = try await ResponseBriefPersistence(url: url).snapshot()
        let stored = try #require(state.receipts.first)
        #expect(stored.request.responseBriefLength == .long)
        #expect(stored.request.prompt == ResponseBriefRequestBuilder.lengthPrompt)
        #expect(!stored.request.prompt.contains("140 words"))
    }

    @Test("A length-selected receipt whose prompt reverted to legacy is rejected")
    func revertedReceiptPromptBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let selected = try makeReceipt(id: "reverted-prompt", length: .medium)
        var request = selected.request
        request.prompt = ResponseBriefRequestBuilder.prompt
        let tampered = ResponseBriefPersistence.Receipt(
            id: selected.id,
            source: selected.source,
            request: request,
            runID: selected.runID,
            createdAt: selected.createdAt,
            status: selected.status
        )
        try writeSnapshot(receipts: [tampered], to: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await ResponseBriefPersistence(url: url).snapshot()
        }
    }

    @Test("A length-selected receipt whose captured selection was stripped is rejected")
    func strippedReceiptLengthBlocksLoad() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "cache.json")
        let selected = try makeReceipt(id: "stripped-length", length: .medium)
        var request = selected.request
        request.responseBriefLength = nil
        let tampered = ResponseBriefPersistence.Receipt(
            id: selected.id,
            source: selected.source,
            request: request,
            runID: selected.runID,
            createdAt: selected.createdAt,
            status: selected.status
        )
        try writeSnapshot(receipts: [tampered], to: url)

        await #expect(throws: ResponseBriefPersistenceError.corruptOrOversized) {
            _ = try await ResponseBriefPersistence(url: url).snapshot()
        }
    }

    @Test("Cache clear preserves identity and regeneration state")
    func clearPreservesDurableIdentityState() async throws {
        let persistence = ResponseBriefPersistence(inMemory: true)
        let source = makeSource(responseID: "entry-a1")
        let chatID = source.chat.id
        try await persistence.recordBaselineAnchor(
            chatID: chatID,
            responseID: "entry-a1",
            identity: nil,
            recordedAt: Date(timeIntervalSince1970: 1)
        )
        try await persistence.recordVerifiedAlias(
            chatID: chatID,
            aliasID: "live:synthetic:1",
            canonicalID: "entry-a1",
            identity: nil,
            verifiedAt: Date(timeIntervalSince1970: 2)
        )
        try await persistence.savePendingRegeneration(.init(
            chatID: chatID,
            source: source,
            length: .long,
            createdAt: Date(timeIntervalSince1970: 3)
        ))

        try await persistence.clearCachedRecords()

        let state = try await persistence.snapshot()
        #expect(state.baselineAnchors[chatID]?.responseID == "entry-a1")
        #expect(state.verifiedAliases[chatID]?.count == 1)
        #expect(state.pendingRegenerations[chatID]?.length == .long)
    }

    @Test("A failed relationship save rolls the new durable state back")
    func relationshipSaveRollsBack() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let persistence = ResponseBriefPersistence(url: blocker.appending(path: "cache.json"))

        var didFail = false
        do {
            try await persistence.recordVerifiedAlias(
                chatID: "synthetic-chat",
                aliasID: "live:synthetic:1",
                canonicalID: "entry-a1",
                identity: nil,
                verifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        } catch {
            didFail = true
        }

        #expect(didFail)
        let state = try await persistence.snapshot()
        #expect(state.verifiedAliases.isEmpty)
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "response-brief-persistence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeReceipt(
        id: String,
        mutation: InvalidRequestMutation? = nil,
        length: ResponseBriefLength? = nil
    ) throws -> ResponseBriefPersistence.Receipt {
        let source = makeSource(responseID: id)
        var request = try ResponseBriefRequestBuilder.request(
            for: source,
            model: nil,
            thinkingLevel: nil,
            clientRequestID: "request-\(id)",
            length: length
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

    private func makeSource(
        responseID: String,
        text: String = "Synthetic answer"
    ) -> ResponseBriefSource {
        ResponseBriefSource(
            chat: .init(machineID: "synthetic-machine", paneID: "w1:p1", sessionID: "synthetic-session"),
            responseID: responseID,
            text: text,
            currentUserText: "Synthetic question",
            previousUserText: nil,
            previousAssistantText: nil
        )
    }

    private func makeCapturedRecord(
        id: String,
        length: ResponseBriefLength,
        summary: String,
        sourceText: String
    ) -> ResponseBriefPersistence.Record {
        ResponseBriefPersistence.Record(
            id: id,
            source: makeSource(responseID: id, text: sourceText),
            brief: ResponseBrief(version: 1, title: "Synthetic", summary: summary, points: [], details: []),
            model: nil,
            thinkingLevel: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            responseBriefLength: length,
            responseBriefLengthPolicyVersion: ResponseBriefLength.policyVersion
        )
    }

    private func writeSnapshot(
        records: [ResponseBriefPersistence.Record] = [],
        receipts: [ResponseBriefPersistence.Receipt] = [],
        baselineAnchors: [String: ResponseBriefPersistence.BaselineAnchor]? = nil,
        verifiedAliases: [String: [ResponseBriefPersistence.VerifiedAlias]]? = nil,
        pendingRegenerations: [String: ResponseBriefPersistence.PendingRegeneration]? = nil,
        regenerationRevisions: [String: Int]? = nil,
        to url: URL
    ) throws {
        let snapshot = StoredSnapshot(
            records: records,
            receipts: receipts,
            baselineAnchors: baselineAnchors,
            verifiedAliases: verifiedAliases,
            pendingRegenerations: pendingRegenerations,
            regenerationRevisions: regenerationRevisions
        )
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

enum TamperedIdentityState: CaseIterable, Sendable {
    case aliasMatchesCanonical
    case invalidEvidenceHash
    case anchorChatMismatch
    case intentChatMismatch
}

private struct StoredSnapshot: Encodable {
    let records: [ResponseBriefPersistence.Record]
    let receipts: [ResponseBriefPersistence.Receipt]
    var baselineAnchors: [String: ResponseBriefPersistence.BaselineAnchor]? = nil
    var verifiedAliases: [String: [ResponseBriefPersistence.VerifiedAlias]]? = nil
    var pendingRegenerations: [String: ResponseBriefPersistence.PendingRegeneration]? = nil
    var regenerationRevisions: [String: Int]? = nil
}
