import Foundation

actor ResponseBriefPersistence {
    struct Record: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let source: ResponseBriefSource
        let brief: ResponseBrief
        let model: String?
        let thinkingLevel: String?
        let createdAt: Date
        /// Captured length selection and policy version. Nil means the record
        /// predates configurable length; absent metadata decodes as legacy and
        /// never rewrites the stored source or request.
        var responseBriefLength: ResponseBriefLength? = nil
        var responseBriefLengthPolicyVersion: Int? = nil
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

    /// Durable identity evidence for a chat's saved baseline response. One
    /// anchor per chat; a newer baseline replaces the older anchor.
    struct BaselineAnchor: Codable, Equatable, Sendable {
        let chatID: String
        let responseID: String
        let identity: ResponseBriefIdentityEvidence?
        let recordedAt: Date
    }

    /// A verified live/persisted alias for one completed answer. Aliases let a
    /// later snapshot resolve a baseline that was saved under the other
    /// projection's identifier.
    struct VerifiedAlias: Codable, Equatable, Sendable {
        let aliasID: String
        let canonicalID: String
        let identity: ResponseBriefIdentityEvidence?
        let verifiedAt: Date
    }

    /// The single coalescible regeneration intent for a chat. A newer length
    /// selection replaces the older intent instead of growing a queue.
    struct PendingRegeneration: Codable, Equatable, Sendable {
        let chatID: String
        let source: ResponseBriefSource
        let length: ResponseBriefLength
        let createdAt: Date
    }

    struct State: Sendable {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: Set<String>
        var responseCursorByChatID: [String: String]
        var baselineAnchors: [String: BaselineAnchor] = [:]
        var verifiedAliases: [String: [VerifiedAlias]] = [:]
        var pendingRegenerations: [String: PendingRegeneration] = [:]
    }

    private struct Snapshot: Codable, Sendable {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: [String]
        var responseCursorByChatID: [String: String]
        var baselineAnchors: [String: BaselineAnchor]
        var verifiedAliases: [String: [VerifiedAlias]]
        var pendingRegenerations: [String: PendingRegeneration]

        private enum CodingKeys: String, CodingKey {
            case records, receipts, attemptedGenerationIDs, responseCursorByChatID
            case baselineAnchors, verifiedAliases, pendingRegenerations
        }

        init(
            records: [Record],
            receipts: [Receipt],
            attemptedGenerationIDs: [String],
            responseCursorByChatID: [String: String],
            baselineAnchors: [String: BaselineAnchor] = [:],
            verifiedAliases: [String: [VerifiedAlias]] = [:],
            pendingRegenerations: [String: PendingRegeneration] = [:]
        ) {
            self.records = records
            self.receipts = receipts
            self.attemptedGenerationIDs = attemptedGenerationIDs
            self.responseCursorByChatID = responseCursorByChatID
            self.baselineAnchors = baselineAnchors
            self.verifiedAliases = verifiedAliases
            self.pendingRegenerations = pendingRegenerations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Records and receipts existed in the predecessor format and are
            // the baseline needed to preserve replay ownership. Newer ledger,
            // cursor, identity, and regeneration fields remain optional for
            // migration.
            records = try container.decode([Record].self, forKey: .records)
            receipts = try container.decode([Receipt].self, forKey: .receipts)
            attemptedGenerationIDs = try container.decodeIfPresent([String].self, forKey: .attemptedGenerationIDs) ?? []
            responseCursorByChatID = try container.decodeIfPresent([String: String].self, forKey: .responseCursorByChatID) ?? [:]
            baselineAnchors = try container.decodeIfPresent([String: BaselineAnchor].self, forKey: .baselineAnchors) ?? [:]
            verifiedAliases = try container.decodeIfPresent([String: [VerifiedAlias]].self, forKey: .verifiedAliases) ?? [:]
            pendingRegenerations = try container.decodeIfPresent([String: PendingRegeneration].self, forKey: .pendingRegenerations) ?? [:]
        }
    }

    private struct MemoryState {
        var records: [Record]
        var receipts: [Receipt]
        var attemptedGenerationIDs: Set<String>
        var responseCursorByChatID: [String: String]
        var baselineAnchors: [String: BaselineAnchor]
        var verifiedAliases: [String: [VerifiedAlias]]
        var pendingRegenerations: [String: PendingRegeneration]
    }

    private let url: URL?
    private let maximumRecords: Int
    private let maximumOutstandingReceipts: Int
    private let maximumBytes: Int
    private let maximumDecodedCollectionCount = 10_000
    private let maximumBaselineAnchors = 40
    private let maximumVerifiedAliasesPerChat = 8
    private let maximumAliasChats = 40
    private let maximumPendingRegenerations = 40
    private var loaded = false
    private var records: [Record] = []
    private var receipts: [Receipt] = []
    private var attemptedGenerationIDs: Set<String> = []
    private var responseCursorByChatID: [String: String] = [:]
    private var baselineAnchors: [String: BaselineAnchor] = [:]
    private var verifiedAliases: [String: [VerifiedAlias]] = [:]
    private var pendingRegenerations: [String: PendingRegeneration] = [:]

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
            responseCursorByChatID: responseCursorByChatID,
            baselineAnchors: baselineAnchors,
            verifiedAliases: verifiedAliases,
            pendingRegenerations: pendingRegenerations
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

    /// Atomically advances a chat's baseline high-watermark and records the
    /// identity evidence for that exact response. A crash between two separate
    /// writes could otherwise strand the baseline after a live-to-persisted
    /// identifier change.
    func advanceCursor(
        chatID: String,
        responseID: String,
        anchorIdentity: ResponseBriefIdentityEvidence?,
        recordedAt: Date
    ) throws {
        try mutateAtomically {
            responseCursorByChatID[chatID] = responseID
            baselineAnchors[chatID] = BaselineAnchor(
                chatID: chatID,
                responseID: responseID,
                identity: anchorIdentity,
                recordedAt: recordedAt
            )
            try trimEvictableContentToLimits()
        }
    }

    /// Records the durable identity anchor for a chat's saved baseline. The
    /// newest anchor for a chat replaces the older one.
    func recordBaselineAnchor(
        chatID: String,
        responseID: String,
        identity: ResponseBriefIdentityEvidence?,
        recordedAt: Date
    ) throws {
        try mutateAtomically {
            baselineAnchors[chatID] = BaselineAnchor(
                chatID: chatID,
                responseID: responseID,
                identity: identity,
                recordedAt: recordedAt
            )
            try trimEvictableContentToLimits()
        }
    }

    func removeBaselineAnchor(chatID: String) throws {
        try mutateAtomically {
            baselineAnchors.removeValue(forKey: chatID)
        }
    }

    /// Records that `aliasID` is a verified alias of `canonicalID` for a chat.
    /// Re-recording an alias replaces the older row instead of accumulating.
    func recordVerifiedAlias(
        chatID: String,
        aliasID: String,
        canonicalID: String,
        identity: ResponseBriefIdentityEvidence?,
        verifiedAt: Date
    ) throws {
        try mutateAtomically {
            var aliases = verifiedAliases[chatID] ?? []
            aliases.removeAll { $0.aliasID == aliasID }
            aliases.append(VerifiedAlias(
                aliasID: aliasID,
                canonicalID: canonicalID,
                identity: identity,
                verifiedAt: verifiedAt
            ))
            aliases.sort { $0.verifiedAt < $1.verifiedAt }
            if aliases.count > maximumVerifiedAliasesPerChat {
                aliases.removeFirst(aliases.count - maximumVerifiedAliasesPerChat)
            }
            verifiedAliases[chatID] = aliases
            try trimEvictableContentToLimits()
        }
    }

    func removeVerifiedAliases(chatID: String) throws {
        try mutateAtomically {
            verifiedAliases.removeValue(forKey: chatID)
        }
    }

    /// Stores the single coalescible regeneration intent for a chat. A newer
    /// selection for the same chat replaces the older intent.
    func savePendingRegeneration(_ intent: PendingRegeneration) throws {
        try mutateAtomically {
            if pendingRegenerations[intent.chatID] == nil,
               pendingRegenerations.count >= maximumPendingRegenerations {
                throw ResponseBriefPersistenceError.tooManyPendingRegenerations
            }
            pendingRegenerations[intent.chatID] = intent
            try trimEvictableContentToLimits()
        }
    }

    func removePendingRegeneration(chatID: String) throws {
        try mutateAtomically {
            pendingRegenerations.removeValue(forKey: chatID)
        }
    }

    /// Clears displayable cache data without destroying replay ownership, the
    /// source high-watermarks that prevent historical backfill, verified
    /// identity anchors/aliases, or coalescible regeneration intents.
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
        baselineAnchors = snapshot.baselineAnchors
        verifiedAliases = snapshot.verifiedAliases
        pendingRegenerations = snapshot.pendingRegenerations
        loaded = true
        try trimEvictableContentToLimits()
    }

    private func validate(_ snapshot: Snapshot) throws {
        let collectionsAreBounded = snapshot.records.count <= maximumDecodedCollectionCount
            && snapshot.receipts.count <= maximumDecodedCollectionCount
            && snapshot.attemptedGenerationIDs.count <= maximumDecodedCollectionCount
            && snapshot.responseCursorByChatID.count <= maximumDecodedCollectionCount
            && snapshot.baselineAnchors.count <= maximumDecodedCollectionCount
            && snapshot.verifiedAliases.count <= maximumDecodedCollectionCount
            && snapshot.pendingRegenerations.count <= maximumDecodedCollectionCount
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
        let anchorsAreValid = snapshot.baselineAnchors.allSatisfy { entry in
            !entry.key.isEmpty
                && entry.key == entry.value.chatID
                && !entry.value.responseID.isEmpty
                && (entry.value.identity.map(Self.isWellFormedEvidence) ?? true)
        }
        let aliasesAreValid = snapshot.verifiedAliases.allSatisfy { entry in
            !entry.key.isEmpty
                && entry.value.count <= maximumDecodedCollectionCount
                && Set(entry.value.map(\.aliasID)).count == entry.value.count
                && entry.value.allSatisfy { alias in
                    !alias.aliasID.isEmpty
                        && !alias.canonicalID.isEmpty
                        && alias.aliasID != alias.canonicalID
                        && (alias.identity.map(Self.isWellFormedEvidence) ?? true)
                }
        }
        let intentsAreValid = snapshot.pendingRegenerations.count <= maximumPendingRegenerations
            && snapshot.pendingRegenerations.allSatisfy { entry in
            !entry.key.isEmpty
                && entry.key == entry.value.chatID
                && entry.value.source.chat.id == entry.key
                && !entry.value.source.responseID.isEmpty
                && (entry.value.source.identity.map(Self.isWellFormedEvidence) ?? true)
        }
        guard anchorsAreValid, aliasesAreValid, intentsAreValid else {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }

        for record in snapshot.records {
            try validateCapturedLength(record)
        }
        for receipt in snapshot.receipts {
            try validateRestoredRequest(receipt.request, for: receipt.source)
        }
    }

    /// A record with captured current-version metadata must still satisfy the
    /// policy it was generated under. Unknown policy versions stay readable so
    /// a future formula change never invalidates existing cache entries.
    private func validateCapturedLength(_ record: Record) throws {
        guard let length = record.responseBriefLength else { return }
        guard record.responseBriefLengthPolicyVersion == ResponseBriefLength.policyVersion else { return }
        guard record.brief.conformsToConcisionPolicy(source: record.source.text, length: length) else {
            throw ResponseBriefPersistenceError.corruptOrOversized
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
        let capturedLength = request.responseBriefLength
        let expectedPrompt = capturedLength == nil
            ? ResponseBriefRequestBuilder.prompt
            : ResponseBriefRequestBuilder.lengthPrompt
        guard let expected = try? ResponseBriefRequestBuilder.request(
            for: source,
            model: request.model,
            thinkingLevel: request.thinkingLevel,
            clientRequestID: request.clientRequestId,
            length: capturedLength
        ),
        request.prompt == expectedPrompt,
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
        request.parentSessionId == source.chat.sessionID,
        request.responseBriefLength == capturedLength
        else {
            throw ResponseBriefPersistenceError.corruptOrOversized
        }
    }

    private static func isWellFormedEvidence(_ evidence: ResponseBriefIdentityEvidence) -> Bool {
        isHash(evidence.responseTextHash)
            && (evidence.userTextHash.map(isHash) ?? true)
    }

    private static func isHash(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func mutateAtomically(_ mutation: () throws -> Void) throws {
        try loadIfNeeded()
        let old = MemoryState(
            records: records,
            receipts: receipts,
            attemptedGenerationIDs: attemptedGenerationIDs,
            responseCursorByChatID: responseCursorByChatID,
            baselineAnchors: baselineAnchors,
            verifiedAliases: verifiedAliases,
            pendingRegenerations: pendingRegenerations
        )
        do {
            try mutation()
            try persist()
        } catch {
            records = old.records
            receipts = old.receipts
            attemptedGenerationIDs = old.attemptedGenerationIDs
            responseCursorByChatID = old.responseCursorByChatID
            baselineAnchors = old.baselineAnchors
            verifiedAliases = old.verifiedAliases
            pendingRegenerations = old.pendingRegenerations
            throw error
        }
    }

    private func trimEvictableContentToLimits() throws {
        records = records.sorted { $0.createdAt < $1.createdAt }
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }
        trimIdentityMetadata()

        // Settled receipts are only explicit-retry conveniences. Pending and
        // ambiguous receipts, and pending regeneration intents, are ownership
        // records and are never evicted.
        while encodedSize() > maximumBytes, !records.isEmpty {
            records.removeFirst()
        }
        while encodedSize() > maximumBytes,
              let index = receipts.enumerated()
                .filter({ $0.element.status == .settled })
                .min(by: { $0.element.createdAt < $1.element.createdAt })?.offset {
            receipts.remove(at: index)
        }
        while encodedSize() > maximumBytes, evictOldestVerifiedAlias() {}
        while encodedSize() > maximumBytes, evictOldestBaselineAnchor() {}
        guard encodedSize() <= maximumBytes else {
            throw ResponseBriefPersistenceError.cacheFull
        }
    }

    private func trimIdentityMetadata() {
        if baselineAnchors.count > maximumBaselineAnchors {
            let excess = baselineAnchors.count - maximumBaselineAnchors
            let oldest = baselineAnchors.values.sorted { $0.recordedAt < $1.recordedAt }
            for anchor in oldest.prefix(excess) {
                baselineAnchors.removeValue(forKey: anchor.chatID)
            }
        }
        for chatID in Array(verifiedAliases.keys) {
            guard let aliases = verifiedAliases[chatID], !aliases.isEmpty else {
                verifiedAliases.removeValue(forKey: chatID)
                continue
            }
            guard aliases.count > maximumVerifiedAliasesPerChat else { continue }
            verifiedAliases[chatID] = Array(
                aliases.sorted { $0.verifiedAt < $1.verifiedAt }
                    .suffix(maximumVerifiedAliasesPerChat)
            )
        }
        if verifiedAliases.count > maximumAliasChats {
            let excess = verifiedAliases.count - maximumAliasChats
            let oldestChats = verifiedAliases
                .map { (chatID: $0.key, newest: $0.value.map(\.verifiedAt).max() ?? .distantPast) }
                .sorted { $0.newest < $1.newest }
            for entry in oldestChats.prefix(excess) {
                verifiedAliases.removeValue(forKey: entry.chatID)
            }
        }
    }

    private func evictOldestVerifiedAlias() -> Bool {
        var oldestChatID: String?
        var oldestAlias: VerifiedAlias?
        for (chatID, aliases) in verifiedAliases {
            for alias in aliases where oldestAlias == nil || alias.verifiedAt < oldestAlias!.verifiedAt {
                oldestChatID = chatID
                oldestAlias = alias
            }
        }
        guard let oldestChatID, let oldestAlias else { return false }
        var aliases = verifiedAliases[oldestChatID] ?? []
        aliases.removeAll { $0.aliasID == oldestAlias.aliasID }
        verifiedAliases[oldestChatID] = aliases.isEmpty ? nil : aliases
        return true
    }

    private func evictOldestBaselineAnchor() -> Bool {
        guard let oldest = baselineAnchors.values.min(by: { $0.recordedAt < $1.recordedAt }) else {
            return false
        }
        baselineAnchors.removeValue(forKey: oldest.chatID)
        return true
    }

    private func encodedSize() -> Int {
        (try? JSONEncoder().encode(snapshotForEncoding()).count) ?? Int.max
    }

    private func snapshotForEncoding() -> Snapshot {
        Snapshot(
            records: records,
            receipts: receipts,
            attemptedGenerationIDs: attemptedGenerationIDs.sorted(),
            responseCursorByChatID: responseCursorByChatID,
            baselineAnchors: baselineAnchors,
            verifiedAliases: verifiedAliases,
            pendingRegenerations: pendingRegenerations
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

extension ResponseBriefPersistence.Record {
    /// The captured length policy for this record. Nil means the record
    /// predates configurable length and must be validated with the legacy
    /// policy, not with whichever length is selected later.
    var capturedConcisionPolicy: ResponseBriefConcisionPolicy? {
        guard let responseBriefLength else { return nil }
        return ResponseBriefConcisionPolicy(source: source.text, length: responseBriefLength)
    }
}

enum ResponseBriefPersistenceError: LocalizedError, Equatable {
    case cacheFull
    case tooManyOutstandingRuns
    case tooManyPendingRegenerations
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
        case .tooManyPendingRegenerations:
            "Too many chats have a response brief regeneration waiting. Let those runs settle before queuing another."
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
