import Foundation

/// The model choice a new-scheme HUD session owns, shaped for persistence.
/// Optional in a snapshot so version-1 caches written before this behavior
/// still decode; an absent value marks a legacy conversation that keeps
/// following the shared HUD preference.
enum HerdrHudPersistedModelChoice: Codable, Equatable, Sendable {
    case machineDefault
    case explicit(provider: String, id: String)

    init(_ choice: HerdrHudModelChoice) {
        switch choice {
        case .machineDefault:
            self = .machineDefault
        case let .explicit(identity):
            self = .explicit(provider: identity.provider, id: identity.id)
        }
    }

    var choice: HerdrHudModelChoice {
        switch self {
        case .machineDefault:
            return .machineDefault
        case let .explicit(provider, id):
            return .explicit(PiModelIdentity(provider: provider, id: id, name: nil))
        }
    }
}

/// Durable ownership of one interrupted checked launch together with the
/// frozen composer input needed to reconnect it after a relaunch. The request
/// identity and receipt stay launcher-owned; this record lets a restored
/// composer present the exact same unresolved launch instead of orphaning the
/// draft or minting a new request ID.
struct HerdrHudPendingWorkspaceLaunch: Codable, Equatable, Sendable {
    let requestID: String?
    let fingerprint: String?
    let receipt: HerdrHudWorkspaceLaunchReceipt?
    let draft: String
    let quotes: [ChatQuote]
    let attachments: [HerdrHudAttachment]
    let selectedMachineID: String?
    let createsInMainWorkspace: Bool
    let updatedAt: Date
}

struct HerdrHudPersistenceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumExchangeCount = 10
    static let maximumResponseBytes = 64 * 1024
    static let truncatedResponseMarker = "\n\n[Response truncated for HUD persistence]"

    let version: Int
    let thread: HerdrHudSession.HerdrHudThread?
    let exchanges: [PersistedExchange]
    let hasUnseenAnswer: Bool?
    let historyRootRunID: String?
    /// Optional cumulative model/cost aggregate. It keeps values beyond the
    /// capped transcript and stays optional so version-1 caches written
    /// before it still decode.
    let chatMetadata: HerdrHudChatMetadataAccumulator?
    /// Optional new-chat model ownership. Absent means the session predates
    /// this behavior and continues to follow the shared legacy preference.
    let modelChoice: HerdrHudPersistedModelChoice?
    /// Optional ownership of an interrupted checked workspace launch. Absent
    /// means no checked launch is pending or the cache predates this field.
    let workspaceLaunch: HerdrHudPendingWorkspaceLaunch?

    init(
        version: Int = HerdrHudPersistenceSnapshot.currentVersion,
        thread: HerdrHudSession.HerdrHudThread?,
        exchanges: [HerdrHudExchange],
        hasUnseenAnswer: Bool = false,
        historyRootRunID: String? = nil,
        chatMetadata: HerdrHudChatMetadataAccumulator? = nil,
        modelChoice: HerdrHudPersistedModelChoice? = nil,
        workspaceLaunch: HerdrHudPendingWorkspaceLaunch? = nil
    ) {
        self.version = version
        self.hasUnseenAnswer = hasUnseenAnswer
        self.historyRootRunID = historyRootRunID
        self.chatMetadata = chatMetadata
        self.modelChoice = modelChoice
        self.workspaceLaunch = workspaceLaunch
        self.thread = thread
        self.exchanges = exchanges.suffix(Self.maximumExchangeCount).map(PersistedExchange.init)
    }

    static func load(from fileURL: URL) -> HerdrHudPersistenceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == Self.currentVersion
        else {
            return nil
        }
        return snapshot
    }

    func save(to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: fileURL, options: .atomic)
    }

    func restoredValues() -> (thread: HerdrHudSession.HerdrHudThread?, exchanges: [HerdrHudExchange]) {
        (
            thread,
            exchanges.map { persistedExchange in
                var exchange = persistedExchange.exchange
                if !exchange.status.isTerminal {
                    exchange.status = .failed
                    exchange.error = "Interrupted by app restart"
                }
                return exchange
            }
        )
    }

    struct PersistedExchange: Codable, Equatable, Sendable {
        let id: String
        let machineID: String
        let prompt: String
        let sentPrompt: String
        let response: String?
        let error: String?
        let status: HeadlessAgentRunStatus
        let costUSD: Double?
        let createdAt: Date
        let promotedPaneID: String?
        let attachmentFilenames: [String]
        /// Optional keeps caches from before folder selection readable; home is
        /// the semantic default when older data has no folder field.
        let workingFolderPath: String?
        let localAttachments: [HerdrHudAttachment]?
        let modelLabel: String
        /// Optional keeps caches written before model attribution was tracked
        /// readable. An absent value means unproven, so a stored catalog guess
        /// is never restored as the executed model.
        let modelLabelIsProven: Bool?
        let steps: [HerdrHudStep]
        let stepsTruncated: Bool

        init(_ exchange: HerdrHudExchange) {
            id = exchange.id
            machineID = exchange.machineID
            prompt = exchange.prompt
            sentPrompt = exchange.sentPrompt
            response = exchange.response.map(Self.cappedResponse)
            error = exchange.error
            status = exchange.status
            costUSD = exchange.costUSD
            createdAt = exchange.createdAt
            promotedPaneID = exchange.promotedPaneID
            attachmentFilenames = exchange.attachmentFilenames
            workingFolderPath = exchange.workingFolderPath == HerdrHudWorkingFolder.homePath
                ? nil : exchange.workingFolderPath
            localAttachments = exchange.localAttachments.isEmpty ? nil : exchange.localAttachments
            modelLabel = exchange.modelLabel
            modelLabelIsProven = exchange.modelLabelIsProven
            steps = exchange.steps
            stepsTruncated = exchange.stepsTruncated
        }

        var exchange: HerdrHudExchange {
            let isProven = modelLabelIsProven ?? false
            return HerdrHudExchange(
                id: id,
                machineID: machineID,
                prompt: prompt,
                sentPrompt: sentPrompt,
                response: response,
                error: error,
                status: status,
                costUSD: costUSD,
                createdAt: createdAt,
                promotedPaneID: promotedPaneID,
                attachmentFilenames: attachmentFilenames,
                workingFolderPath: HerdrHudWorkingFolder.normalizedPath(workingFolderPath ?? HerdrHudWorkingFolder.homePath)
                    ?? HerdrHudWorkingFolder.homePath,
                attachments: [],
                localAttachments: localAttachments ?? [],
                modelLabel: isProven ? modelLabel : "default",
                modelLabelIsProven: isProven,
                steps: steps,
                stepsTruncated: stepsTruncated
            )
        }

        private static func cappedResponse(_ response: String) -> String {
            let data = Data(response.utf8)
            guard data.count > HerdrHudPersistenceSnapshot.maximumResponseBytes else { return response }

            let marker = HerdrHudPersistenceSnapshot.truncatedResponseMarker
            let byteLimit = HerdrHudPersistenceSnapshot.maximumResponseBytes - marker.utf8.count
            var prefix = Data(data.prefix(byteLimit))
            while String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
            return String(decoding: prefix, as: UTF8.self) + marker
        }
    }
}

actor HerdrHudPersistenceStore {
    let fileURL: URL
    private var pendingSnapshot: HerdrHudPersistenceSnapshot?
    private var isSaveScheduled = false

    init(fileURL: URL = HerdrHudPersistenceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "herdr-harness-mac"
        return applicationSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("hud-thread.json", isDirectory: false)
    }

    func load() -> HerdrHudPersistenceSnapshot? {
        HerdrHudPersistenceSnapshot.load(from: fileURL)
    }

    func scheduleSave(_ snapshot: HerdrHudPersistenceSnapshot) {
        pendingSnapshot = snapshot
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.writePendingSnapshots()
        }
    }

    /// Writes through the same latest-wins path, without handing the write to
    /// an unstructured task. A checked launch persists its ownership and
    /// frozen input this way before it creates anything, so a crash cannot
    /// strand a request ID that was never written to disk.
    func saveImmediately(_ snapshot: HerdrHudPersistenceSnapshot) {
        pendingSnapshot = snapshot
        writePendingSnapshots()
    }

    /// Launch admission requires a successful write, unlike best-effort history caching.
    /// Clear an older queued snapshot so it cannot overwrite this ownership record.
    func saveDurably(_ snapshot: HerdrHudPersistenceSnapshot) throws {
        pendingSnapshot = nil
        try snapshot.save(to: fileURL)
    }

    func remove() {
        pendingSnapshot = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func writePendingSnapshots() {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            try? snapshot.save(to: fileURL)
        }
        isSaveScheduled = false
    }
}
