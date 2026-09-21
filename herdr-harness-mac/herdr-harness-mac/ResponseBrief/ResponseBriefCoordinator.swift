import CryptoKit
import Foundation
import Observation

@MainActor
struct ResponseBriefTransport {
    var capabilities: (String) async throws -> AssistantCapabilities
    var models: (String) async throws -> AgentModelCatalogResponse
    var fetchSnapshot: (ResponseBriefChatIdentity) async throws -> PiConversationSnapshot
    var start: (String, AssistantRequest) async throws -> HeadlessAgentRun
    var fetch: (String, String) async throws -> HeadlessAgentRun
    var cancel: (String, String) async throws -> HeadlessAgentRun
}

@MainActor
@Observable
final class ResponseBriefCoordinator {
    enum Phase: Equatable {
        case idle
        case checkingSupport
        case generating
        case regenerateNeeded(String)
        case unsupported
        case upgradeRequired(String)
        case baselineUnmatched(String)
        case oversized
        case failed(String)
    }

    struct ChatState: Equatable {
        var sourceID: String?
        var phase: Phase = .idle
        var runID: String?
        var notice: String?
    }

    private struct GenerationConfiguration: Equatable {
        let model: String?
        let thinkingLevel: String?
    }

    private struct Job {
        let source: ResponseBriefSource
        let configuration: GenerationConfiguration
        let generationID: String
        /// The captured length selection for this request. Nil replays a
        /// legacy receipt or request that predates configurable length.
        let length: ResponseBriefLength?
        /// Stable marker for a coalescible length replacement. Non-nil only
        /// for replacement jobs driven by a durable pending intent.
        let replacementKey: String?
        let force: Bool
        let allowsNonPendingReceipt: Bool
        /// User-initiated replacement, regeneration, or retry. Deliberate jobs
        /// may create a fresh generation even when a saved brief exists.
        let isDeliberate: Bool
    }

    private struct ActiveOperation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private(set) var records: [ResponseBriefPersistence.Record] = []
    private(set) var states: [String: ChatState] = [:]
    private(set) var modelsByMachine: [String: [PiAvailableModel]] = [:]
    private(set) var selectedModel: String?
    private(set) var thinkingLevel: String?
    private(set) var isLoaded = false
    private(set) var preferencesRevision = 0
    private(set) var storageError: String?

    private let preferences: ResponseBriefPreferences
    @ObservationIgnored private let persistence: ResponseBriefPersistence
    @ObservationIgnored private var receipts: [String: ResponseBriefPersistence.Receipt] = [:]
    @ObservationIgnored private var attemptedGenerationIDs: Set<String> = []
    @ObservationIgnored private var responseCursorByChatID: [String: String] = [:]
    @ObservationIgnored private var baselineAnchors: [String: ResponseBriefPersistence.BaselineAnchor] = [:]
    @ObservationIgnored private var verifiedAliases: [String: [ResponseBriefPersistence.VerifiedAlias]] = [:]
    @ObservationIgnored private var pendingRegenerations: [String: ResponseBriefPersistence.PendingRegeneration] = [:]
    @ObservationIgnored private var responseBriefCapabilities: [String: AssistantCapabilities.ResponseBriefs] = [:]
    @ObservationIgnored private var latestSources: [String: ResponseBriefSource] = [:]
    @ObservationIgnored private var operations: [String: ActiveOperation] = [:]
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var isConnectionChanging = false
    private var supportedMachines: Set<String> = []
    private var unsupportedMachines: Set<String> = []
    @ObservationIgnored private var pollFailureCounts: [String: Int] = [:]
    @ObservationIgnored private var nextPollAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let generationDeadlineNow: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let globalConcurrencyLimit = 2
    @ObservationIgnored private let maximumQueuedPerChat = 8
    @ObservationIgnored var runPollDelay: Duration = .seconds(1)
    @ObservationIgnored var generationTimeout: Duration = .seconds(120)

    init(
        defaults: UserDefaults = .standard,
        persistence: ResponseBriefPersistence = ResponseBriefPersistence(),
        generationDeadlineNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        preferences = ResponseBriefPreferences(defaults: defaults)
        self.persistence = persistence
        self.generationDeadlineNow = generationDeadlineNow
        selectedModel = preferences.model
        thinkingLevel = preferences.thinkingLevel
    }

    var enabledChats: [ResponseBriefChatIdentity] {
        _ = preferencesRevision
        return preferences.enabledChats
    }

    /// The app-wide length preference. Selecting a new value through
    /// `changeLength` regenerates the currently selected source.
    var length: ResponseBriefLength {
        _ = preferencesRevision
        return preferences.length
    }

    func isEnabled(_ chat: ResponseBriefChatIdentity) -> Bool {
        _ = preferencesRevision
        return preferences.isEnabled(chat)
    }

    func state(for chat: ResponseBriefChatIdentity) -> ChatState {
        if let storageError {
            guard let state = states[chat.id], state.phase != .idle else {
                return ChatState(phase: .failed(storageError))
            }
            return state
        }
        return states[chat.id] ?? ChatState()
    }

    func isUnsupported(machineID: String) -> Bool {
        unsupportedMachines.contains(machineID)
    }

    func briefs(for chat: ResponseBriefChatIdentity) -> [ResponseBriefPersistence.Record] {
        records
            .filter {
                $0.source.chat.machineID == chat.machineID
                    && $0.source.chat.sessionID == chat.sessionID
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func hasNonconformingBrief(for source: ResponseBriefSource) -> Bool {
        records.contains {
            areEquivalent($0.source, source)
                && !$0.briefConformsToCapturedPolicy
        }
    }

    func source(
        for state: ChatState,
        in chat: ResponseBriefChatIdentity
    ) -> ResponseBriefSource? {
        guard let sourceID = state.sourceID else { return nil }
        if let receipt = receipts.values
            .filter({ $0.source.chat.id == chat.id && $0.source.id == sourceID })
            .max(by: { $0.createdAt < $1.createdAt }) {
            return receipt.source
        }
        if let record = records
            .filter({ $0.source.chat.id == chat.id && $0.source.id == sourceID })
            .max(by: { $0.createdAt < $1.createdAt }) {
            return record.source
        }
        guard latestSources[chat.id]?.id == sourceID else { return nil }
        return latestSources[chat.id]
    }

    func canRegenerate(_ source: ResponseBriefSource) -> Bool {
        isLoaded
            && ResponseBriefConcisionPolicy(source: source.text, length: length).metrics.shouldGenerate
            && operations[source.chat.id] == nil
            && !receipts.values.contains {
                $0.source.chat.id == source.chat.id && $0.status != .settled
            }
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            let snapshot = try await persistence.snapshot()
            records = snapshot.records
            receipts = Dictionary(uniqueKeysWithValues: snapshot.receipts.map { ($0.id, $0) })
            attemptedGenerationIDs = snapshot.attemptedGenerationIDs
            responseCursorByChatID = snapshot.responseCursorByChatID
            baselineAnchors = snapshot.baselineAnchors
            verifiedAliases = snapshot.verifiedAliases
            pendingRegenerations = snapshot.pendingRegenerations
        } catch {
            storageError = error.localizedDescription
        }
        isLoaded = true
    }

    @discardableResult
    func enable(_ chat: ResponseBriefChatIdentity) -> Bool {
        let enabled = preferences.enable(chat)
        if enabled {
            preferencesRevision &+= 1
            if let storageError {
                states[chat.id] = ChatState(phase: .failed(storageError))
            }
        } else {
            states[chat.id] = ChatState(
                phase: .failed("At most \(ResponseBriefPreferences.maximumEnabledChats) chats can be opted in at once. Turn off another chat first.")
            )
        }
        return enabled
    }

    func disable(_ chat: ResponseBriefChatIdentity, transport: ResponseBriefTransport) {
        preferences.disable(chat)
        preferencesRevision &+= 1
        latestSources.removeValue(forKey: chat.id)
        pollFailureCounts[chat.id] = nil
        nextPollAt[chat.id] = nil
        pending.removeAll { $0.source.chat.id == chat.id }
        if pendingRegenerations.removeValue(forKey: chat.id) != nil {
            Task { try? await persistence.removePendingRegeneration(chatID: chat.id) }
        }

        // Keep the slot until the operation has either learned the run ID and
        // cancelled it, or durably recorded that ownership is ambiguous.
        if let operation = operations[chat.id] {
            operation.task.cancel()
        } else if let receipt = receipts.values.first(where: {
            $0.source.chat.id == chat.id && $0.status != .settled
        }) {
            enqueueCancellationReconciliation(receipt, transport: transport)
        } else {
            states[chat.id] = ChatState()
        }
    }

    func selectModel(_ model: String?) {
        selectedModel = model
        preferences.replaceModel(model)
    }

    func selectThinkingLevel(_ level: String?) {
        thinkingLevel = level
        preferences.replaceThinkingLevel(level)
    }

    /// The single app-wide length action. It stores the preference, then
    /// starts a durable replacement for the currently selected source (or the
    /// latest completed source for the chat) without changing opt-in, model,
    /// or thinking. Selecting the current value is a no-op.
    func changeLength(
        _ newLength: ResponseBriefLength,
        chat: ResponseBriefChatIdentity?,
        selectedSource: ResponseBriefSource?,
        transport: ResponseBriefTransport
    ) async {
        await load()
        guard newLength != length else { return }
        preferences.replaceLength(newLength)
        preferencesRevision &+= 1
        guard let chat, canDispatch(for: chat) else { return }
        let target: ResponseBriefSource?
        if let selectedSource, selectedSource.chat == chat {
            target = selectedSource
        } else {
            target = latestSources[chat.id]
        }
        guard let target else { return }
        await requestReplacement(for: target, length: newLength, transport: transport)
    }

    func prepare(machineID: String, transport: ResponseBriefTransport) async {
        await load()
        guard storageError == nil, !unsupportedMachines.contains(machineID) else { return }
        do {
            if !supportedMachines.contains(machineID) {
                let capabilities = try await transport.capabilities(machineID)
                guard capabilities.profiles.contains("response-brief-v1") else {
                    responseBriefCapabilities.removeValue(forKey: machineID)
                    unsupportedMachines.insert(machineID)
                    return
                }
                supportedMachines.insert(machineID)
                responseBriefCapabilities[machineID] = capabilities.responseBriefs
            }
            if modelsByMachine[machineID] == nil {
                let catalog = try await transport.models(machineID)
                modelsByMachine[machineID] = catalog.models
                // A nil selection deliberately remains the server default. A
                // machine's default must not become a global explicit choice.
            }
        } catch {
            // A transient capability/catalog failure is not cached. A later
            // operation or explicit refresh can retry after an upgrade.
        }
    }

    func refreshSupport(machineID: String, transport: ResponseBriefTransport) async {
        supportedMachines.remove(machineID)
        unsupportedMachines.remove(machineID)
        modelsByMachine.removeValue(forKey: machineID)
        responseBriefCapabilities.removeValue(forKey: machineID)
        await prepare(machineID: machineID, transport: transport)
        for chat in enabledChats where chat.machineID == machineID {
            if unsupportedMachines.contains(machineID) {
                states[chat.id] = ChatState(phase: .unsupported)
            } else if supportedMachines.contains(machineID), modelsByMachine[machineID] != nil {
                states[chat.id] = ChatState()
                if let source = latestSources[chat.id] {
                    enqueue(source, transport: transport, force: true)
                }
            } else {
                states[chat.id] = ChatState(
                    phase: .failed("Couldn't refresh response brief support. Try again when this machine is connected.")
                )
            }
        }
    }

    /// Latest-only observation used by a mounted view. Once a batch cursor
    /// exists this intentionally does not advance it: the next chronological
    /// snapshot can still discover completions between the old cursor and this
    /// latest source.
    func observe(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        latestSources[source.chat.id] = source

        if responseCursorByChatID[source.chat.id] == nil {
            guard await advanceCursor(to: source) else { return }
        }
        resumePendingReceipt(for: source.chat, transport: transport)
        resumePendingRegeneration(for: source.chat, transport: transport)
        enqueue(source, transport: transport)
    }

    /// Ingests all eligible final answers in chronological order. The first
    /// observation establishes a baseline and generates only the newest answer;
    /// later snapshots queue every completion after the durable high-watermark.
    /// A live-to-persisted identifier change is reconciled only through durable
    /// verified identity evidence; ambiguous history stays on the warning path.
    func observeSources(_ sources: [ResponseBriefSource], transport: ResponseBriefTransport) async {
        await load()
        guard let latest = sources.last, canDispatch(for: latest.chat) else { return }
        let chat = latest.chat
        latestSources[chat.id] = latest
        resumePendingReceipt(for: chat, transport: transport)
        resumePendingRegeneration(for: chat, transport: transport)
        drain(transport: transport)

        let candidates: ArraySlice<ResponseBriefSource>
        if let cursor = responseCursorByChatID[chat.id] {
            if let cursorIndex = sources.lastIndex(where: { $0.responseID == cursor }) {
                candidates = sources[sources.index(after: cursorIndex)...]
            } else if let resolution = resolveBaseline(cursor: cursor, chatID: chat.id, sources: sources) {
                guard await recordVerifiedAlias(
                    aliasID: cursor,
                    canonical: resolution,
                    chatID: chat.id
                ) else { return }
                guard await advanceCursor(to: resolution) else { return }
                guard let resolvedIndex = sources.lastIndex(where: {
                    $0.responseID == resolution.responseID
                }) else { return }
                candidates = sources[sources.index(after: resolvedIndex)...]
            } else {
                states[chat.id] = ChatState(
                    sourceID: latest.id,
                    phase: .baselineUnmatched("Some completed responses could not be matched to the saved brief baseline. No historical backfill was started.")
                )
                return
            }
        } else {
            candidates = sources.suffix(1)
        }

        let alreadyQueued = pending.count(where: { $0.source.chat.id == chat.id })
        let capacity = max(0, maximumQueuedPerChat - alreadyQueued)
        let accepted = Array(candidates.prefix(capacity))
        if candidates.count > accepted.count {
            states[chat.id] = ChatState(
                sourceID: latest.id,
                phase: .failed("Response brief work is catching up. New completed responses remain queued by the saved baseline and were not discarded."),
                notice: "Brief queue is bounded to \(maximumQueuedPerChat) responses per chat."
            )
        }

        for source in accepted {
            enqueue(source, transport: transport)
        }
        if let lastAccepted = accepted.last {
            guard await advanceCursor(to: lastAccepted) else { return }
        }
        drain(transport: transport)
    }

    /// Explicit latest-only recovery for an unmatched baseline. It always
    /// establishes a durable new baseline before generating, and never
    /// backfills or replays the unmatched history. Accepted work is resumed so
    /// ownership is reconciled rather than discarded.
    func restartBriefsFromLatest(
        _ chat: ResponseBriefChatIdentity,
        transport: ResponseBriefTransport
    ) async {
        await load()
        guard canDispatch(for: chat) else { return }
        resumePendingReceipt(for: chat, transport: transport)
        drain(transport: transport)

        var latest = latestSources[chat.id]
        if let snapshot = try? await transport.fetchSnapshot(chat) {
            var reducer = PiConversationReducer()
            reducer.replace(with: snapshot)
            if reducer.sessionID == chat.sessionID {
                let sources = ResponseBriefSource.completedSources(
                    turns: reducer.turns,
                    machineID: chat.machineID,
                    paneID: chat.paneID,
                    sessionID: chat.sessionID
                )
                if let persistedLatest = sources.last {
                    latest = persistedLatest
                }
            }
        }
        guard let latest else {
            states[chat.id] = ChatState(
                sourceID: nil,
                phase: .failed("The latest completed response is not available yet. Wait for this chat to finish, then try again.")
            )
            return
        }
        latestSources[chat.id] = latest
        guard await advanceCursor(to: latest) else { return }
        states[chat.id] = ChatState(sourceID: latest.id, phase: .idle)
        enqueue(latest, transport: transport)
        drain(transport: transport)
    }

    func retry(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        let unresolved = receipts.values
            .filter { areEquivalent($0.source, source) && $0.status != .settled }
            .max { $0.createdAt < $1.createdAt }
        if let receipt = unresolved {
            states[source.chat.id] = ChatState(sourceID: receipt.source.id, phase: .idle)
            enqueue(job(for: receipt, force: true), transport: transport)
        } else if records.contains(where: { areEquivalent($0.source, source) }) {
            states[source.chat.id] = ChatState(
                sourceID: source.id,
                phase: .regenerateNeeded("A brief already exists for this response. Regenerate to create a fresh request.")
            )
        } else {
            states[source.chat.id] = ChatState(sourceID: source.id, phase: .idle)
            enqueue(source, transport: transport, force: true)
        }
    }

    func regenerate(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        guard ResponseBriefConcisionPolicy(source: source.text, length: length).metrics.shouldGenerate else {
            return
        }
        let hasUnresolvedChatReceipt = receipts.values.contains {
            $0.source.chat.id == source.chat.id && $0.status != .settled
        }
        if operations[source.chat.id] != nil || hasUnresolvedChatReceipt {
            // Reconcile accepted ownership instead of stranding it; the
            // explicit regeneration can be requested again once it settles.
            resumePendingReceipt(for: source.chat, transport: transport)
            drain(transport: transport)
            states[source.chat.id] = ChatState(
                sourceID: source.id,
                phase: .failed("Wait for the current response brief run to settle before regenerating.")
            )
            return
        }
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let job = Job(
            source: source,
            configuration: configuration,
            generationID: generationIdentity(for: source, configuration: configuration, length: length)
                + ":regenerate:" + UUID().uuidString,
            length: length,
            replacementKey: nil,
            force: true,
            allowsNonPendingReceipt: false,
            isDeliberate: true
        )
        enqueue(job, transport: transport)
    }

    func clearCache() async throws {
        await load()
        if let storageError { throw ResponseBriefCoordinatorError.storageUnavailable(storageError) }
        guard operations.isEmpty, pending.isEmpty else {
            throw ResponseBriefCoordinatorError.activeRunsPreventClear
        }
        try await persistence.clearCachedRecords()
        records = []
        receipts = receipts.filter { $0.value.status != .settled }
        states = states.mapValues { state in
            var next = state
            if next.phase == .idle { next.sourceID = nil }
            return next
        }
    }

    func connectionDidChange() async {
        // Do not erase receipts or queued sources. An old request may have been
        // accepted while its connection was being replaced.
        isConnectionChanging = true
        let active = operations.values.map(\.task)
        active.forEach { $0.cancel() }
        for task in active { await task.value }
        isConnectionChanging = false
        supportedMachines = []
        unsupportedMachines = []
        pollFailureCounts = [:]
        nextPollAt = [:]
        modelsByMachine = [:]
        responseBriefCapabilities = [:]
    }

    func waitForIdleForTesting() async {
        while let operation = operations.values.first {
            await operation.task.value
        }
    }

    func runPolling(transport: ResponseBriefTransport) async {
        await load()
        guard storageError == nil else { return }
        let clock = ContinuousClock()
        while !Task.isCancelled {
            for chat in enabledChats {
                if let retryAt = nextPollAt[chat.id], retryAt > clock.now { continue }
                do {
                    let snapshot = try await transport.fetchSnapshot(chat)
                    try Task.checkCancellation()
                    pollFailureCounts[chat.id] = nil
                    nextPollAt[chat.id] = nil
                    var reducer = PiConversationReducer()
                    reducer.replace(with: snapshot)
                    guard reducer.sessionID == chat.sessionID else {
                        disable(chat, transport: transport)
                        continue
                    }
                    resumePendingReceipt(for: chat, transport: transport)
                    drain(transport: transport)
                    let sources = ResponseBriefSource.completedSources(
                        turns: reducer.turns,
                        machineID: chat.machineID,
                        paneID: chat.paneID,
                        sessionID: chat.sessionID
                    )
                    await observeSources(sources, transport: transport)
                } catch is CancellationError {
                    return
                } catch {
                    let failures = min((pollFailureCounts[chat.id] ?? 0) + 1, 5)
                    pollFailureCounts[chat.id] = failures
                    nextPollAt[chat.id] = clock.now.advanced(
                        by: .seconds(min(30, 1 << failures))
                    )
                }
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func canDispatch(for chat: ResponseBriefChatIdentity) -> Bool {
        guard isEnabled(chat) else { return false }
        if let storageError {
            states[chat.id] = ChatState(phase: .failed(storageError))
            return false
        }
        return true
    }

    /// Advances the durable baseline high-watermark together with the identity
    /// evidence observed for that exact response. A crash between separate
    /// writes could otherwise strand the baseline after an identifier change.
    private func advanceCursor(to source: ResponseBriefSource) async -> Bool {
        let recordedAt = Date.now
        do {
            try await persistence.advanceCursor(
                chatID: source.chat.id,
                responseID: source.responseID,
                anchorIdentity: source.identity,
                recordedAt: recordedAt
            )
            responseCursorByChatID[source.chat.id] = source.responseID
            baselineAnchors[source.chat.id] = .init(
                chatID: source.chat.id,
                responseID: source.responseID,
                identity: source.identity,
                recordedAt: recordedAt
            )
            return true
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
            return false
        }
    }

    /// Resolves a saved baseline identifier against a snapshot using only
    /// durable evidence. Exact identifiers and previously verified aliases
    /// match first; otherwise continuity must be proven by identity evidence
    /// from the baseline anchor or the newest owned source. Text, labels,
    /// ordering, and display names are never identity.
    private func resolveBaseline(
        cursor: String,
        chatID: String,
        sources: [ResponseBriefSource]
    ) -> ResponseBriefSource? {
        if let exact = sources.last(where: { $0.responseID == cursor }) {
            return exact
        }
        let canonical = canonicalResponseID(cursor, chatID: chatID)
        if canonical != cursor, let aliased = sources.last(where: { $0.responseID == canonical }) {
            return aliased
        }
        if let anchor = baselineAnchors[chatID], anchor.responseID == cursor, let identity = anchor.identity {
            return ResponseBriefIdentity.uniqueVerifiedCandidate(
                responseID: cursor,
                identity: identity,
                among: sources
            )
        }
        // Migrate a baseline saved before anchors existed only when an owned
        // source for that same baseline verifies a unique candidate.
        let owned = (records.map(\.source) + receipts.values.map(\.source))
            .filter { $0.chat.id == chatID && $0.responseID == cursor }
        for candidate in owned {
            guard let identity = candidate.identity else { continue }
            if let resolved = ResponseBriefIdentity.uniqueVerifiedCandidate(
                responseID: cursor,
                identity: identity,
                among: sources
            ) {
                return resolved
            }
        }
        return nil
    }

    private func recordVerifiedAlias(
        aliasID: String,
        canonical: ResponseBriefSource,
        chatID: String
    ) async -> Bool {
        guard aliasID != canonical.responseID else { return true }
        let identity = baselineAnchors[chatID].flatMap { $0.responseID == aliasID ? $0.identity : nil }
            ?? canonical.identity
        let verifiedAt = Date.now
        do {
            try await persistence.recordVerifiedAlias(
                chatID: chatID,
                aliasID: aliasID,
                canonicalID: canonical.responseID,
                identity: identity,
                verifiedAt: verifiedAt
            )
            var aliases = verifiedAliases[chatID] ?? []
            aliases.removeAll { $0.aliasID == aliasID }
            aliases.append(.init(
                aliasID: aliasID,
                canonicalID: canonical.responseID,
                identity: identity,
                verifiedAt: verifiedAt
            ))
            aliases.sort { $0.verifiedAt < $1.verifiedAt }
            verifiedAliases[chatID] = aliases
            return true
        } catch {
            noteStorageFailure(error, chat: canonical.chat, sourceID: canonical.id)
            return false
        }
    }

    private func canonicalResponseID(_ responseID: String, chatID: String) -> String {
        guard let aliases = verifiedAliases[chatID], !aliases.isEmpty else { return responseID }
        var current = responseID
        for _ in 0..<8 {
            guard let next = aliases.last(where: { $0.aliasID == current })?.canonicalID,
                  next != current
            else { break }
            current = next
        }
        return current
    }

    /// Equates two projections of one completed answer without ever using
    /// text alone. Exact identifiers and verified identity evidence are the
    /// only accepted relationships, plus durable aliases proven earlier.
    private func areEquivalent(_ lhs: ResponseBriefSource, _ rhs: ResponseBriefSource) -> Bool {
        guard lhs.chat == rhs.chat else { return false }
        if lhs.responseID == rhs.responseID { return true }
        if ResponseBriefIdentity.match(lhs, rhs) != nil { return true }
        return lhs.sourceHash == rhs.sourceHash
            && canonicalResponseID(lhs.responseID, chatID: lhs.chat.id)
                == canonicalResponseID(rhs.responseID, chatID: rhs.chat.id)
    }

    private func hasOwnedGeneration(
        for source: ResponseBriefSource,
        configuration: GenerationConfiguration,
        includeAttempts: Bool
    ) -> Bool {
        if records.contains(where: { areEquivalent($0.source, source) }) { return true }
        if receipts.values.contains(where: { areEquivalent($0.source, source) }) { return true }
        if includeAttempts,
           let intent = pendingRegenerations[source.chat.id],
           areEquivalent(intent.source, source) {
            return true
        }
        guard includeAttempts else { return false }
        var candidates = [source]
        candidates.append(contentsOf: records.map(\.source))
        candidates.append(contentsOf: receipts.values.map(\.source))
        for candidate in candidates where areEquivalent(candidate, source) {
            let explicit = generationIdentity(for: candidate, configuration: configuration, length: length)
            let legacy = generationIdentity(for: candidate, configuration: configuration, length: nil)
            if attemptedGenerationIDs.contains(explicit) || attemptedGenerationIDs.contains(legacy) {
                return true
            }
        }
        return false
    }

    private func ownsEquivalentGeneration(
        _ source: ResponseBriefSource,
        excluding generationID: String
    ) -> Bool {
        records.contains { $0.id != generationID && areEquivalent($0.source, source) }
            || receipts.values.contains { $0.id != generationID && areEquivalent($0.source, source) }
    }

    private func replacementKey(for intent: ResponseBriefPersistence.PendingRegeneration) -> String {
        [
            intent.chatID,
            intent.source.id,
            intent.length.rawValue,
            String(intent.createdAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
        ].joined(separator: "|")
    }

    /// Stores the single coalescible replacement intent for the chat and
    /// queues it. Accepted ownership is never rewritten; the replacement waits
    /// behind any unresolved receipt through the normal drain serialization.
    private func requestReplacement(
        for source: ResponseBriefSource,
        length: ResponseBriefLength,
        transport: ResponseBriefTransport
    ) async {
        let intent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: length,
            createdAt: .now
        )
        do {
            try await persistence.savePendingRegeneration(intent)
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
            return
        }
        pendingRegenerations[source.chat.id] = intent
        // An unsubmitted automatic job for this exact answer is superseded by
        // the durable intent; an older intent job is dropped by the key check.
        pending.removeAll { job in
            job.source.chat.id == source.chat.id
                && !job.isDeliberate
                && areEquivalent(job.source, source)
        }
        resumePendingReceipt(for: source.chat, transport: transport)
        resumePendingRegeneration(for: source.chat, transport: transport)
        drain(transport: transport)
    }

    private func resumePendingReceipt(for chat: ResponseBriefChatIdentity, transport: ResponseBriefTransport) {
        // An active operation already owns any unresolved receipt for this chat.
        // Queuing that same receipt again would leave a stale replay behind if
        // cancellation settles it before the queued job reaches the front.
        guard operations[chat.id] == nil,
              let receipt = receipts.values
            .filter({ $0.source.chat.id == chat.id && $0.status == .pending })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first
        else { return }
        enqueue(job(for: receipt), transport: transport)
    }

    /// Replays the durable replacement intent after relaunch. The job identity
    /// is derived from the intent's recorded timestamp, so resumption cannot
    /// create a second paid request for one selection.
    private func resumePendingRegeneration(
        for chat: ResponseBriefChatIdentity,
        transport: ResponseBriefTransport
    ) {
        guard isEnabled(chat), let intent = pendingRegenerations[chat.id] else { return }
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let key = replacementKey(for: intent)
        let id = generationIdentity(for: intent.source, configuration: configuration, length: intent.length)
            + ":length:" + key
        // Once a receipt exists the run owns the replacement; resuming it again
        // on every poll would only queue duplicate copies of the same request.
        guard receipts[id] == nil else { return }
        let job = Job(
            source: intent.source,
            configuration: configuration,
            generationID: id,
            length: intent.length,
            replacementKey: key,
            force: false,
            allowsNonPendingReceipt: false,
            isDeliberate: true
        )
        enqueue(job, transport: transport)
    }

    private func clearPendingRegeneration(key: String, chatID: String) async {
        guard let intent = pendingRegenerations[chatID], replacementKey(for: intent) == key else { return }
        pendingRegenerations.removeValue(forKey: chatID)
        do {
            try await persistence.removePendingRegeneration(chatID: chatID)
        } catch {
            // The receipt now owns the work, so a lingering intent can only
            // deduplicate against that same request on the next load.
        }
    }

    private func enqueue(
        _ source: ResponseBriefSource,
        transport: ResponseBriefTransport,
        force: Bool = false
    ) {
        guard !hasNonconformingBrief(for: source) else { return }
        guard ResponseBriefConcisionPolicy(source: source.text, length: length).metrics.shouldGenerate else {
            return
        }
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        if hasOwnedGeneration(for: source, configuration: configuration, includeAttempts: !force) {
            return
        }
        let job = Job(
            source: source,
            configuration: configuration,
            generationID: generationIdentity(for: source, configuration: configuration, length: length),
            length: length,
            replacementKey: nil,
            force: force,
            allowsNonPendingReceipt: false,
            isDeliberate: force
        )
        enqueue(job, transport: transport)
    }

    private func enqueue(_ job: Job, transport: ResponseBriefTransport) {
        let id = job.generationID
        if !job.force {
            if records.contains(where: { $0.id == id }) { return }
            if let receipt = receipts[id] {
                guard receipt.status == .pending else { return }
            } else if job.replacementKey == nil, attemptedGenerationIDs.contains(id) {
                // Durable replacement intent never POSTs before its receipt is
                // saved, so replaying a pre-receipt attempt cannot duplicate
                // paid work and may recover after a relaunch.
                return
            }
        }
        if pending.contains(where: { $0.generationID == id }) { return }
        if operations[job.source.chat.id] != nil,
           receipts[id] == nil,
           pending.count(where: { $0.source.chat.id == job.source.chat.id }) >= maximumQueuedPerChat {
            states[job.source.chat.id] = ChatState(
                sourceID: job.source.id,
                phase: .failed("The bounded brief queue is full. This response remains behind the saved completion baseline and was not silently replaced.")
            )
            return
        }
        pending.append(job)
        drain(transport: transport)
    }

    private func drain(transport: ResponseBriefTransport) {
        // Receipt disposition can change while a job waits behind another run.
        // Drop stale automatic work rather than replaying a run that cancellation
        // or terminal handling has already settled. Explicit retry/regenerate
        // jobs remain eligible through their explicit job markers.
        pending.removeAll { !isEligibleToStart($0) }
        while operations.count < globalConcurrencyLimit,
              let index = pending.firstIndex(where: { job in
                  operations[job.source.chat.id] == nil
                      && !receipts.values.contains(where: {
                          $0.source.chat.id == job.source.chat.id
                              && $0.id != job.generationID
                              && $0.status != .settled
                      })
              }) {
            let job = pending.remove(at: index)
            guard isEligibleToStart(job) else { continue }
            let chatID = job.source.chat.id
            let token = UUID()
            let task = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.generate(job, token: token, transport: transport)
            }
            operations[chatID] = ActiveOperation(token: token, task: task)
        }
    }

    private func isEligibleToStart(_ job: Job) -> Bool {
        guard isEnabled(job.source.chat), storageError == nil else { return false }
        guard !records.contains(where: { $0.id == job.generationID }) else { return false }
        if let receipt = receipts[job.generationID] {
            return receipt.status == .pending || job.allowsNonPendingReceipt
        }
        if let key = job.replacementKey {
            guard let intent = pendingRegenerations[job.source.chat.id],
                  replacementKey(for: intent) == key
            else { return false }
            return true
        } else if !job.isDeliberate,
                  ownsEquivalentGeneration(job.source, excluding: job.generationID) {
            // Another projection of this same answer already has a record or
            // receipt. Drop the duplicate instead of paying for it again.
            return false
        }
        return job.force || !attemptedGenerationIDs.contains(job.generationID)
    }

    private func finishOperation(chatID: String, token: UUID, transport: ResponseBriefTransport) {
        guard operations[chatID]?.token == token else { return }
        operations[chatID] = nil
        guard !isConnectionChanging else { return }
        if !enabledChats.contains(where: { $0.id == chatID }),
           let receipt = receipts.values.first(where: {
               $0.source.chat.id == chatID && $0.status == .pending
           }) {
            enqueueCancellationReconciliation(receipt, transport: transport)
        } else {
            drain(transport: transport)
        }
    }

    private func generate(_ job: Job, token: UUID, transport: ResponseBriefTransport) async {
        let source = job.source
        let chatID = source.chat.id
        let deadline = generationDeadlineNow().advanced(by: generationTimeout)
        let deadlineNotice = Task<Void, Never> { @MainActor [weak self] in
            do { try await Task.sleep(for: self?.generationTimeout ?? .seconds(120)) }
            catch { return }
            guard let self, self.operations[chatID]?.token == token else { return }
            self.states[chatID] = ChatState(
                sourceID: source.id,
                phase: .failed(ResponseBriefCoordinatorError.timedOut.localizedDescription),
                runID: self.receipts[job.generationID]?.runID,
                notice: "The request may have been accepted. Its saved ownership receipt will be reconciled before another run can start."
            )
        }
        defer {
            deadlineNotice.cancel()
            finishOperation(chatID: chatID, token: token, transport: transport)
        }
        guard isEligibleToStart(job) else { return }
        if records.contains(where: { $0.id == job.generationID }) {
            states[chatID] = ChatState(sourceID: source.id, phase: .idle)
            return
        }
        if receipts[job.generationID] == nil {
            if attemptedGenerationIDs.contains(job.generationID), !job.force, job.replacementKey == nil {
                return
            }
            do {
                try await persistence.markAttempted(id: job.generationID)
                attemptedGenerationIDs.insert(job.generationID)
            } catch {
                noteStorageFailure(error, chat: source.chat, sourceID: source.id)
                return
            }
        }

        states[chatID] = ChatState(sourceID: source.id, phase: .checkingSupport)
        await prepare(machineID: source.chat.machineID, transport: transport)
        guard generationDeadlineNow() < deadline else {
            states[chatID] = ChatState(sourceID: source.id, phase: .failed(ResponseBriefCoordinatorError.timedOut.localizedDescription))
            return
        }
        guard isEnabled(source.chat), !Task.isCancelled else { return }
        guard supportedMachines.contains(source.chat.machineID) else {
            states[chatID] = ChatState(
                sourceID: source.id,
                phase: unsupportedMachines.contains(source.chat.machineID)
                    ? .unsupported
                    : .failed("Couldn't check response brief support. Try again when this machine is connected.")
            )
            return
        }
        guard let catalog = modelsByMachine[source.chat.machineID] else {
            states[chatID] = ChatState(
                sourceID: source.id,
                phase: .failed("Couldn't load the response brief model catalog. Retry support after reconnecting.")
            )
            return
        }
        if let model = job.configuration.model, !catalog.contains(where: { $0.id == model }) {
            states[chatID] = ChatState(
                sourceID: source.id,
                phase: .failed("The selected response brief model “\(model)” is unavailable on this machine. Choose an available model or the server default.")
            )
            return
        }

        var receipt: ResponseBriefPersistence.Receipt
        do {
            if let saved = receipts[job.generationID] {
                // Accepted ownership is reconciled under its captured
                // configuration before any fresh capability check or
                // replacement starts. A legacy receipt must never be stranded
                // by an old server or by an upgraded length selection.
                receipt = saved
            } else {
                if job.length != nil {
                    guard let advertised = responseBriefCapabilities[source.chat.machineID],
                          advertised.supportsEveryLengthOption else {
                        // Drop the cached support result so an explicit retry
                        // refetches capabilities after the companion upgrades.
                        supportedMachines.remove(source.chat.machineID)
                        responseBriefCapabilities.removeValue(forKey: source.chat.machineID)
                        states[chatID] = ChatState(
                            sourceID: source.id,
                            phase: .upgradeRequired("Update the companion for configurable brief length (\(ResponseBriefLength.options.joined(separator: ", "))). This request was not sent and no fallback was used.")
                        )
                        return
                    }
                }
                let request = try ResponseBriefRequestBuilder.request(
                    for: source,
                    model: job.configuration.model,
                    thinkingLevel: job.configuration.thinkingLevel,
                    length: job.length
                )
                receipt = .init(
                    id: job.generationID,
                    source: source,
                    request: request,
                    runID: nil,
                    createdAt: .now
                )
                try await persistence.saveReceipt(receipt)
                receipts[job.generationID] = receipt
                attemptedGenerationIDs.insert(job.generationID)
            }
        } catch let error as ResponseBriefRequestError {
            do {
                try await persistence.markAttempted(id: job.generationID)
                attemptedGenerationIDs.insert(job.generationID)
            } catch {
                noteStorageFailure(error, chat: source.chat, sourceID: source.id)
                return
            }
            states[chatID] = ChatState(sourceID: source.id, phase: .oversized)
            _ = error
            return
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
            return
        }
        if let key = job.replacementKey {
            await clearPendingRegeneration(key: key, chatID: chatID)
        }

        if Task.isCancelled || !isEnabled(source.chat) {
            await reconcileCancellation(receipt: receipt, source: source, transport: transport)
            return
        }

        states[chatID] = ChatState(sourceID: source.id, phase: .generating, runID: receipt.runID)
        do {
            var run: HeadlessAgentRun
            if let runID = receipt.runID {
                run = try await transport.fetch(source.chat.machineID, runID)
            } else {
                run = try await transport.start(source.chat.machineID, receipt.request)
                receipt.runID = run.id
                receipt.status = .pending
                do {
                    try await persistence.saveReceipt(receipt)
                    receipts[job.generationID] = receipt
                } catch {
                    receipts[job.generationID] = receipt
                    let persistenceError = error
                    if !run.status.isTerminal {
                        do {
                            let cancelled = try await cancelWithoutInheritedCancellation(
                                machineID: source.chat.machineID,
                                runID: run.id,
                                transport: transport
                            )
                            guard cancelled.status.isTerminal else {
                                throw ResponseBriefCoordinatorError.cancellationFailed(
                                    "The server did not settle the run after cancellation."
                                )
                            }
                        } catch {
                            let message = "Couldn't persist the accepted run (\(persistenceError.localizedDescription)); remote cancellation also failed: \(error.localizedDescription)"
                            storageError = message
                            states[chatID] = ChatState(
                                sourceID: source.id,
                                phase: .failed(message),
                                runID: run.id
                            )
                            return
                        }
                    }
                    noteStorageFailure(persistenceError, chat: source.chat, sourceID: source.id)
                    return
                }
                states[chatID]?.runID = run.id
            }

            if Task.isCancelled || !isEnabled(source.chat) {
                await reconcileCancellation(receipt: receipt, source: source, knownRun: run, transport: transport)
                return
            }
            if generationDeadlineNow() >= deadline {
                try await cancelForDeadline(receipt: &receipt, source: source, run: run, transport: transport)
                throw ResponseBriefCoordinatorError.timedOut
            }

            run = try await observeRun(
                run,
                source: source,
                deadline: deadline,
                transport: transport
            )
            guard run.status == .completed, let response = run.response else {
                receipt.status = .settled
                try await saveUpdatedReceipt(receipt)
                throw ResponseBriefCoordinatorError.runFailed(run.error ?? "The brief request did not complete.")
            }

            let brief: ResponseBrief
            do {
                brief = try ResponseBrief.decodeValidated(
                    Data(response.utf8),
                    source: source.text,
                    length: job.length
                )
            } catch {
                receipt.status = .settled
                try await saveUpdatedReceipt(receipt)
                throw error
            }
            let record = ResponseBriefPersistence.Record(
                id: job.generationID,
                source: source,
                brief: brief,
                model: job.configuration.model,
                thinkingLevel: job.configuration.thinkingLevel,
                createdAt: .now,
                responseBriefLength: job.length,
                responseBriefLengthPolicyVersion: job.length == nil ? nil : ResponseBriefLength.policyVersion
            )
            try await persistence.saveRecord(record)
            records.removeAll { $0.id == job.generationID }
            records.append(record)
            records = Array(records.sorted { $0.createdAt < $1.createdAt }.suffix(40))
            receipts.removeValue(forKey: job.generationID)
            states[chatID] = ChatState(sourceID: source.id, phase: .idle)
        } catch is CancellationError {
            await reconcileCancellation(receipt: receipt, source: source, transport: transport)
        } catch let error as ResponseBriefValidationError {
            if storageError != nil { return }
            states[chatID] = ChatState(
                sourceID: source.id,
                phase: .regenerateNeeded(error.localizedDescription),
                runID: receipts[job.generationID]?.runID
            )
        } catch {
            if storageError != nil { return }
            if var saved = receipts[job.generationID], saved.status == .pending {
                saved.status = .needsExplicitRetry
                do { try await saveUpdatedReceipt(saved) }
                catch {
                    noteStorageFailure(error, chat: source.chat, sourceID: source.id)
                    return
                }
            }
            states[chatID] = ChatState(
                sourceID: source.id,
                phase: .failed(error.localizedDescription),
                runID: receipts[job.generationID]?.runID
            )
        }
    }

    private func observeRun(
        _ initialRun: HeadlessAgentRun,
        source: ResponseBriefSource,
        deadline: ContinuousClock.Instant,
        transport: ResponseBriefTransport
    ) async throws -> HeadlessAgentRun {
        var run = initialRun
        var failures = 0
        while !run.status.isTerminal {
            try Task.checkCancellation()
            guard generationDeadlineNow() < deadline else {
                var receipt = try requiredReceipt(for: source, runID: run.id)
                try await cancelForDeadline(receipt: &receipt, source: source, run: run, transport: transport)
                throw ResponseBriefCoordinatorError.timedOut
            }
            do {
                let requestedDelay = failures == 0 ? runPollDelay : .seconds(min(8, failures * 2))
                let remaining = generationDeadlineNow().duration(to: deadline)
                let delay = min(requestedDelay, remaining)
                if delay > .zero { try await Task.sleep(for: delay) }
                else { await Task.yield() }
                run = try await transport.fetch(source.chat.machineID, run.id)
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures >= 8 { throw error }
            }
        }
        return run
    }

    private func requiredReceipt(for source: ResponseBriefSource, runID: String) throws -> ResponseBriefPersistence.Receipt {
        guard let receipt = receipts.values.first(where: { $0.source.id == source.id && $0.runID == runID }) else {
            throw ResponseBriefCoordinatorError.missingReceipt
        }
        return receipt
    }

    private func cancelForDeadline(
        receipt: inout ResponseBriefPersistence.Receipt,
        source: ResponseBriefSource,
        run: HeadlessAgentRun,
        transport: ResponseBriefTransport
    ) async throws {
        if !run.status.isTerminal {
            do {
                let cancelled = try await cancelWithoutInheritedCancellation(
                    machineID: source.chat.machineID,
                    runID: run.id,
                    transport: transport
                )
                guard cancelled.status.isTerminal else {
                    throw ResponseBriefCoordinatorError.cancellationFailed("The server did not settle the run after cancellation.")
                }
            } catch {
                receipt.status = .needsExplicitRetry
                try await saveUpdatedReceipt(receipt)
                throw ResponseBriefCoordinatorError.cancellationFailed(error.localizedDescription)
            }
        }
        receipt.status = .settled
        try await saveUpdatedReceipt(receipt)
    }

    private func reconcileCancellation(
        receipt: ResponseBriefPersistence.Receipt,
        source: ResponseBriefSource,
        knownRun: HeadlessAgentRun? = nil,
        transport: ResponseBriefTransport
    ) async {
        var receipt = receipt
        guard let runID = knownRun?.id ?? receipt.runID else {
            receipt.status = .needsExplicitRetry
            do { try await saveUpdatedReceipt(receipt) }
            catch { noteStorageFailure(error, chat: source.chat, sourceID: source.id) }
            states[source.chat.id] = ChatState(
                sourceID: source.id,
                phase: .failed("The request may have been accepted before cancellation. Retry will safely replay the same receipt."),
                runID: nil
            )
            return
        }

        if knownRun?.status.isTerminal != true {
            do {
                let cancelled = try await cancelWithoutInheritedCancellation(
                    machineID: source.chat.machineID,
                    runID: runID,
                    transport: transport
                )
                guard cancelled.status.isTerminal else {
                    throw ResponseBriefCoordinatorError.cancellationFailed("The server did not settle the run after cancellation.")
                }
            } catch {
                receipt.runID = runID
                receipt.status = .needsExplicitRetry
                do { try await saveUpdatedReceipt(receipt) }
                catch { noteStorageFailure(error, chat: source.chat, sourceID: source.id); return }
                states[source.chat.id] = ChatState(
                    sourceID: source.id,
                    phase: .failed("The owned response brief run could not be cancelled: \(error.localizedDescription)"),
                    runID: runID
                )
                return
            }
        }

        receipt.runID = runID
        receipt.status = .settled
        do {
            try await saveUpdatedReceipt(receipt)
            states[source.chat.id] = ChatState(sourceID: source.id, phase: .idle)
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
        }
    }

    private func enqueueCancellationReconciliation(
        _ receipt: ResponseBriefPersistence.Receipt,
        transport: ResponseBriefTransport
    ) {
        let chatID = receipt.source.chat.id
        guard operations[chatID] == nil else { return }
        let token = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileCancellation(receipt: receipt, source: receipt.source, transport: transport)
            self.finishOperation(chatID: chatID, token: token, transport: transport)
        }
        operations[chatID] = ActiveOperation(token: token, task: task)
    }

    private func cancelWithoutInheritedCancellation(
        machineID: String,
        runID: String,
        transport: ResponseBriefTransport
    ) async throws -> HeadlessAgentRun {
        let cancellation = Task<HeadlessAgentRun, Error> { @MainActor in
            try await transport.cancel(machineID, runID)
        }
        return try await cancellation.value
    }

    private func saveUpdatedReceipt(_ receipt: ResponseBriefPersistence.Receipt) async throws {
        try await persistence.saveReceipt(receipt)
        receipts[receipt.id] = receipt
    }

    private func noteStorageFailure(_ error: Error, chat: ResponseBriefChatIdentity, sourceID: String?) {
        let message = "Couldn't safely update the private brief cache: \(error.localizedDescription)"
        storageError = message
        states[chat.id] = ChatState(sourceID: sourceID, phase: .failed(message))
    }

    private func job(for receipt: ResponseBriefPersistence.Receipt, force: Bool = false) -> Job {
        Job(
            source: receipt.source,
            configuration: GenerationConfiguration(
                model: receipt.request.model,
                thinkingLevel: receipt.request.thinkingLevel
            ),
            generationID: receipt.id,
            length: receipt.request.responseBriefLength,
            replacementKey: nil,
            force: force,
            allowsNonPendingReceipt: force,
            isDeliberate: true
        )
    }

    /// Generation identity for one source and configuration. Legacy requests
    /// (nil length) keep the exact predecessor material so restored receipts
    /// remain findable. New requests add the chosen preset and policy version.
    private func generationIdentity(
        for source: ResponseBriefSource,
        configuration: GenerationConfiguration,
        length: ResponseBriefLength?
    ) -> String {
        var material = [
            source.chat.machineID,
            source.chat.sessionID,
            source.responseID,
            source.sourceHash,
            String(ResponseBriefLimits.templateVersion),
            configuration.model ?? "default",
            configuration.thinkingLevel ?? "default",
        ]
        if let length {
            material.append(length.rawValue)
            material.append("length-policy-\(ResponseBriefLength.policyVersion)")
        }
        return SHA256.hash(data: Data(material.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ResponseBriefCoordinatorError: LocalizedError {
    case runFailed(String)
    case timedOut
    case cancellationFailed(String)
    case storageUnavailable(String)
    case activeRunsPreventClear
    case missingReceipt
    case networkingDisabled

    var errorDescription: String? {
        switch self {
        case let .runFailed(message): message
        case .timedOut: "The response brief exceeded its two-minute deadline. Its remote run may still be settling."
        case let .cancellationFailed(message): "The response brief deadline expired, but remote cancellation failed: \(message)"
        case let .storageUnavailable(message): message
        case .activeRunsPreventClear: "Wait for active response brief runs to settle before clearing the cache."
        case .missingReceipt: "The response brief run no longer has a durable ownership receipt."
        case .networkingDisabled: "Response brief networking is disabled in demo and test isolation."
        }
    }
}
