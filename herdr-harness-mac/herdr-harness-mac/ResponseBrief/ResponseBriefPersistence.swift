import Foundation

actor ResponseBriefPersistence {
    struct Record: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let source: ResponseBriefSource
        let brief: ResponseBrief
        let model: String?
        let thinkingLevel: String?
        let createdAt: Date
    }

    struct Receipt: Codable, Identifiable, Sendable {
        enum Status: String, Codable, Sendable {
            case pending
            case needsExplicitRetry
            case settled
        }

        let id: String
        let source: ResponseBriefSource
        let request: AssistantRequest
        var runID: String?
        let createdAt: Date
        var status: Status

        init(
            id: String,
            source: ResponseBriefSource,
            request: AssistantRequest,
            runID: String?,
            createdAt: Date,
            status: Status = .pending
        ) {
            self.id = id
            self.source = source
            self.request = request
            self.runID = runID
            self.createdAt = createdAt
            self.status = status
        }

        private enum CodingKeys: String, CodingKey {
            case id, source, request, runID, createdAt, status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            source = try container.decode(ResponseBriefSource.self, forKey: .source)
            request = try container.decode(AssistantRequest.self, forKey: .request)
            runID = try container.decodeIfPresent(String.self, forKey: .runID)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        }
    }

    struct State: Sendable {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: Set<String>
        var responseCursorByChatID: [String: String]
    }

    private struct Snapshot: Codable, Sendable {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: [String]
        var responseCursorByChatID: [String: String]

        private enum CodingKeys: String, CodingKey {
            case records, receipts, attemptedGenerationIDs, responseCursorByChatID
        }

        init(
            records: [Record],
            receipts: [Receipt],
            attemptedGenerationIDs: [String],
            responseCursorByChatID: [String: String]
        ) {
            self.records = records
            self.receipts = receipts
            self.attemptedGenerationIDs = attemptedGenerationIDs
            self.responseCursorByChatID = responseCursorByChatID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Records and receipts existed in the predecessor format and are
            // the baseline needed to preserve replay ownership. Newer ledger
            // and cursor fields remain optional for migration.
            records = try container.decode([Record].self, forKey: .records)
            receipts = try container.decode([Receipt].self, forKey: .receipts)
            attemptedGenerationIDs = try container.decodeIfPresent([String].self, forKey: .attemptedGenerationIDs) ?? []
            responseCursorByChatID = try container.decodeIfPresent([String: String].self, forKey: .responseCursorByChatID) ?? [:]
        }
    }

    private struct MemoryState {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: Set<String>
        var responseCursorByChatID: [String: String]
    }

    private let url: URL?
    private let maximumRecords: Int
    private let maximumOutstandingReceipts: Int
    private let maximumBytes: Int
    private let maximumDecodedCollectionCount = 10_000
    private var loaded = false
    private var records: [Record] = []
    private var receipts: [Receipt] = []
    private var attemptedGenerationIDs: Set<String> = []
    private var responseCursorByChatID: [String: String] = [:]

    init(
        url: URL? = nil,
        maximumRecords: Int = 40,
        maximumOutstandingReceipts: Int = 40,
        maximumBytes: Int = 4 * 1_024 * 1_024,
        inMemory: Bool = false
    ) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = inMemory
            ? nil
            : (url ?? root.appending(path: "Herdr/response-briefs-v1.json", directoryHint: .notDirectory))
        self.maximumRecords = maximumRecords
        self.maximumOutstandingReceipts = maximumOutstandingReceipts
        self.maximumBytes = maximumBytes
    }

    func snapshot() throws -> State {
        try loadIfNeeded()
        return State(
            records: records,
            receipts: receipts,
            attemptedGenerationIDs: attemptedGenerationIDs,
            responseCursorByChatID: responseCursorByChatID
        )
    }

    func saveReceipt(_ receipt: Receipt) throws {
        try mutateAtomically {
            if !receipts.contains(where: { $0.id == receipt.id }),
               receipts.count(where: { $0.status != .settled }) >= maximumOutstandingReceipts {
                throw ResponseBriefPersistenceError.tooManyOutstandingRuns
            }
            receipts.removeAll { $0.id == receipt.id }
            receipts.append(receipt)
            attemptedGenerationIDs.insert(receipt.id)
            try trimEvictableContentToLimits()
        }
    }

    func saveRecord(_ record: Record) throws {
        try mutateAtomically {
            records.removeAll { $0.id == record.id }
            records.append(record)
            receipts.removeAll { $0.id == record.id }
            attemptedGenerationIDs.insert(record.id)
            try trimEvictableContentToLimits()
        }
    }

    func removeReceipt(id: String) throws {
        try mutateAtomically {
            receipts.removeAll { $0.id == id }
        }
    }

    func removeRecord(id: String) throws {
        try mutateAtomically {
            records.removeAll { $0.id == id }
        }
    }

    func resetAttempt(id: String) throws {
        try mutateAtomically {
            if let receipt = receipts.first(where: { $0.id == id }), receipt.status != .settled {
                throw ResponseBriefPersistenceError.runStillUnresolved
            }
            receipts.removeAll { $0.id == id }
            records.removeAll { $0.id == id }
            attemptedGenerationIDs.remove(id)
        }
    }

    func markAttempted(id: String) throws {
        try mutateAtomically {
            attemptedGenerationIDs.insert(id)
            try trimEvictableContentToLimits()
        }
    }

    func advanceCursor(chatID: String, responseID: String) throws {
        try mutateAtomically {
            responseCursorByChatID[chatID] = responseID
        }
    }

    /// Clears displayable cache data without destroying replay ownership or the
    /// source high-watermarks that prevent historical backfill.
    func clearCachedRecords() throws {
        try mutateAtomically {
            guard !receipts.contains(where: { $0.status != .settled }) else {
                throw ResponseBriefPersistenceError.outstandingRunsPreventClear
            }
            records = []
            receipts.removeAll { $0.status == .settled }
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard let url else {
            loaded = true
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded = true
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ResponseBriefPersistenceError.unreadable(error.localizedDescription)
        }
        guard data.count <= maximumBytes else {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }
        try validate(snapshot)
        records = snapshot.records
        receipts = snapshot.receipts
        attemptedGenerationIDs = Set(snapshot.attemptedGenerationIDs)
        responseCursorByChatID = snapshot.responseCursorByChatID
        loaded = true
        try trimEvictableContentToLimits()
    }

    private func validate(_ snapshot: Snapshot) throws {
        let collectionsAreBounded = snapshot.records.count <= maximumDecodedCollectionCount
            && snapshot.receipts.count <= maximumDecodedCollectionCount
            && snapshot.attemptedGenerationIDs.count <= maximumDecodedCollectionCount
            && snapshot.responseCursorByChatID.count <= maximumDecodedCollectionCount
        let recordIDs = snapshot.records.map(\.id)
        let receiptIDs = snapshot.receipts.map(\.id)
        let attemptedIDs = snapshot.attemptedGenerationIDs
        let identifiersAreUnique = Set(recordIDs).count == recordIDs.count
            && Set(receiptIDs).count == receiptIDs.count
            && Set(attemptedIDs).count == attemptedIDs.count
            && Set(recordIDs).isDisjoint(with: Set(receiptIDs))
        let unresolvedCount = snapshot.receipts.count { $0.status != .settled }
        guard collectionsAreBounded,
              identifiersAreUnique,
              unresolvedCount <= maximumOutstandingReceipts,
              !recordIDs.contains(where: \.isEmpty),
              !receiptIDs.contains(where: \.isEmpty),
              !attemptedIDs.contains(where: \.isEmpty),
              snapshot.responseCursorByChatID.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty })
        else {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }

        for receipt in snapshot.receipts {
            try validateRestoredRequest(receipt.request, for: receipt.source)
        }
    }

    private func validateRestoredRequest(
        _ request: AssistantRequest,
        for source: ResponseBriefSource
    ) throws {
        let requiredText = request.context.items
            .filter { $0.priority == "required" }
            .map(\.text)
            .joined()
        guard let expected = try? ResponseBriefRequestBuilder.request(
            for: source,
            model: request.model,
            thinkingLevel: request.thinkingLevel,
            clientRequestID: request.clientRequestId
        ),
        request.prompt == ResponseBriefRequestBuilder.prompt,
        request.profile == "response-brief-v1",
        request.mode == "ask",
        request.paneId == source.chat.paneID,
        request.scope.expectedRootPath == nil,
        request.context.version == expected.context.version,
        request.context.source == expected.context.source,
        request.context.source.feature == "chat.response-brief",
        request.context.source.instanceId == source.responseID,
        request.context.items == expected.context.items,
        requiredText == source.text,
        request.continueFromRunId == nil,
        request.parentSessionId == source.chat.sessionID
        else {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }
    }

    private func mutateAtomically(_ mutation: () throws -> Void) throws {
        try loadIfNeeded()
        let old = MemoryState(
            records: records,
            receipts: receipts,
            attemptedGenerationIDs: attemptedGenerationIDs,
            responseCursorByChatID: responseCursorByChatID
        )
        do {
            try mutation()
            try persist()
        } catch {
            records = old.records
            receipts = old.receipts
            attemptedGenerationIDs = old.attemptedGenerationIDs
            responseCursorByChatID = old.responseCursorByChatID
            throw error
        }
    }

    private func trimEvictableContentToLimits() throws {
        records = records.sorted { $0.createdAt < $1.createdAt }
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }

        // Settled receipts are only explicit-retry conveniences. Pending and
        // ambiguous receipts are ownership records and are never evicted.
        while encodedSize() > maximumBytes, !records.isEmpty {
            records.removeFirst()
        }
        while encodedSize() > maximumBytes,
              let index = receipts.enumerated()
                .filter({ $0.element.status == .settled })
                .min(by: { $0.element.createdAt < $1.element.createdAt })?.offset {
            receipts.remove(at: index)
        }
        guard encodedSize() <= maximumBytes else {
            throw ResponseBriefPersistenceError.cacheFull
        }
    }

    private func encodedSize() -> Int {
        (try? JSONEncoder().encode(snapshotForEncoding()).count) ?? Int.max
    }

    private func snapshotForEncoding() -> Snapshot {
        Snapshot(
            records: records,
            receipts: receipts,
            attemptedGenerationIDs: attemptedGenerationIDs.sorted(),
            responseCursorByChatID: responseCursorByChatID
        )
    }

    private func persist() throws {
        guard let url else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(snapshotForEncoding())
        guard data.count <= maximumBytes else { throw ResponseBriefPersistenceError.cacheFull }

        // Prepare and permission the complete replacement before the rename so
        // a failed write never leaves disk ahead of the rolled-back memory state.
        let temporaryURL = directory.appending(
            path: ".response-briefs-\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}

enum ResponseBriefPersistenceError: LocalizedError, Equatable {
    case cacheFull
    case tooManyOutstandingRuns
    case outstandingRunsPreventClear
    case runStillUnresolved
    case corruptOrOversized
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .cacheFull:
            "The private response brief cache is full. Resolve outstanding runs before creating more briefs."
        case .tooManyOutstandingRuns:
            "Too many response brief runs still need reconciliation. Resolve them before creating another brief."
        case .outstandingRunsPreventClear:
            "The cache cannot be cleared while a response brief run still needs reconciliation."
        case .runStillUnresolved:
            "This response brief run is still active and cannot be regenerated yet."
        case .corruptOrOversized:
            "The private response brief cache is corrupt or unexpectedly large. Brief generation is blocked to avoid duplicating a paid run."
        case let .unreadable(message):
            "The private response brief cache could not be read (\(message)). Brief generation is blocked to avoid duplicating a paid run."
        }
    }
}
