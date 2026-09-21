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
        /// The selection revision captured with `replacementKey`. Non-nil
        /// exactly when this job is a coalescible length replacement. A newer
        /// selection advances the coordinator epoch before its own durable
        /// write returns, so this revision lets an older unowned job detect
        /// supersession while the previous intent is still stored.
        let replacementRevision: Int?
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
    /// Monotonic per-chat selection/cancellation epoch. Disabling a chat or
    /// selecting a newer length advances it, which invalidates any durable
    /// intent publication that was still suspended before the change so an
    /// obsolete replacement can never be installed or resumed later.
    @ObservationIgnored private var chatEpochs: [String: Int] = [:]
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
    /// Test-only suspension point immediately before a durable regeneration
    /// intent is written. Persistence-barrier regressions use it to interleave
    /// a disable or a newer selection with the awaited save. Nil in the app.
    @ObservationIgnored var intentPersistenceBarrier: (@MainActor () async -> Void)?

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
            // Selection revisions are only comparable across processes when
            // the durable watermark seeds the local counter. Otherwise a
            // post-relaunch selection could allocate a lower revision than an
            // intent this cache already rejected or cancelled.
            for (chatID, revision) in snapshot.regenerationRevisions {
                chatEpochs[chatID] = max(chatEpochs[chatID] ?? 0, revision)
            }
            for (chatID, intent) in snapshot.pendingRegenerations {
                chatEpochs[chatID] = max(chatEpochs[chatID] ?? 0, intent.revision)
            }
            // An intent owned by a chat that is not enabled cannot become
            // current work: new selections are only accepted while enabled and
            // disabling tombstones them. This is upgrade residue or a disable
            // whose tombstone write failed, so remove it durably before a later
            // re-enable could resume obsolete work.
            let enabledChatIDs = Set(preferences.enabledChats.map(\.id))
            for (chatID, intent) in snapshot.pendingRegenerations where !enabledChatIDs.contains(chatID) {
                try await persistence.cancelPendingRegeneration(
                    chatID: chatID,
                    revision: intent.revision
                )
                pendingRegenerations.removeValue(forKey: chatID)
            }
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

    func disable(_ chat: ResponseBriefChatIdentity, transport: ResponseBriefTransport) async {
        // Load first so the local revision counter starts from the durable
        // watermark; otherwise a disable before the first load could allocate a
        // revision an existing intent already superseded.
        await load()
        preferences.disable(chat)
        preferencesRevision &+= 1
        // Disabling supersedes any replacement work that is waiting to be
        // published or resumed for this chat.
        let epoch = advanceChatEpoch(for: chat.id)
        latestSources.removeValue(forKey: chat.id)
        pollFailureCounts[chat.id] = nil
        nextPollAt[chat.id] = nil
        pending.removeAll { $0.source.chat.id == chat.id }
        pendingRegenerations.removeValue(forKey: chat.id)
        // Cancel any owned run, then durably tombstone the cancellation before
        // returning so a delayed older intent write can never be resumed after
        // a relaunch.
        if let operation = operations[chat.id] {
            operation.task.cancel()
        }
        do {
            try await persistence.cancelPendingRegeneration(chatID: chat.id, revision: epoch)
        } catch {
            noteStorageFailure(error, chat: chat, sourceID: nil)
        }

        // Keep the slot until the operation has either learned the run ID and
        // cancelled it, or durably recorded that ownership is ambiguous.
        if operations[chat.id] == nil,
           let receipt = receipts.values.first(where: {
               $0.source.chat.id == chat.id && $0.status != .settled
           }) {
            enqueueCancellationReconciliation(receipt, transport: transport)
        } else if operations[chat.id] == nil {
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
                if pendingRegenerations[chat.id] != nil {
                    // A deliberate replacement waiting behind this machine's
                    // revalidated support owns the next request. Resuming the
                    // intent keeps exactly one submission for the selection
                    // instead of creating an ordinary duplicate.
                    resumePendingReceipt(for: chat, transport: transport)
                    resumePendingRegeneration(for: chat, transport: transport)
                    drain(transport: transport)
                } else if let source = latestSources[chat.id] {
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
        } else if responseCursorByChatID[source.chat.id] == source.responseID {
            // The observed source is already the saved baseline, so an older
            // unmatched warning is obsolete.
            clearObsoleteBaselineWarning(chatID: source.chat.id, latestSourceID: source.id)
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
                clearObsoleteBaselineWarning(chatID: chat.id, latestSourceID: latest.id)
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
                clearObsoleteBaselineWarning(chatID: chat.id, latestSourceID: latest.id)
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
    /// backfills or replays the unmatched history. Accepted work, including a
    /// transport-uncertain submission, is reconciled through its captured
    /// receipt instead of being discarded or hidden.
    func restartBriefsFromLatest(
        _ chat: ResponseBriefChatIdentity,
        transport: ResponseBriefTransport
    ) async {
        await load()
        guard canDispatch(for: chat) else { return }
        // Reserve the recovery revision before the snapshot fetch suspends. A
        // newer length selection, disable/re-enable, or cancellation advances
        // the epoch while the fetch is in flight, so this confirmed recovery
        // must be revalidated against that ordering before it can mutate the
        // baseline or publish work. Reserving here also supersedes any older
        // intent publication that is still suspended for this chat.
        let recoveryEpoch = supersedeOlderWork(for: chat.id)
        resumePendingReceipt(for: chat, transport: transport)
        replayUncertainReceiptForRecovery(for: chat, transport: transport)
        // Make the reservation durable before the snapshot fetch. The same
        // write tombstones any older unsubmitted selection that the epoch
        // reservation already invalidated in memory, so an in-process
        // supersession and a later relaunch agree. Accepted receipts started
        // above are unaffected.
        do {
            try await persistence.cancelPendingRegeneration(chatID: chat.id, revision: recoveryEpoch)
        } catch {
            noteStorageFailure(error, chat: chat, sourceID: nil)
            return
        }
        // Keep memory aligned with the tombstone: an older in-memory intent is
        // gone durably, while a newer selection admitted during the awaits
        // above is preserved in both places.
        if (pendingRegenerations[chat.id]?.revision ?? 0) <= recoveryEpoch {
            pendingRegenerations.removeValue(forKey: chat.id)
        }
        resumePendingRegeneration(for: chat, transport: transport)
        drain(transport: transport)

        var latest = latestSources[chat.id]
        if let snapshot = try? await transport.fetchSnapshot(chat) {
            guard isCurrentRecovery(chat: chat, epoch: recoveryEpoch) else { return }
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
        // Revalidate before every baseline or intent mutation below. A
        // superseded recovery leaves the newer selection and the existing
        // baseline untouched instead of replacing them with latest-only work.
        guard isCurrentRecovery(chat: chat, epoch: recoveryEpoch) else { return }
        guard let latest else {
            states[chat.id] = ChatState(
                sourceID: nil,
                phase: .failed("The latest completed response is not available yet. Wait for this chat to finish, then try again.")
            )
            return
        }
        latestSources[chat.id] = latest

        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let needsBrief = ResponseBriefConcisionPolicy(source: latest.text, length: length).metrics.shouldGenerate
            && !hasNonconformingBrief(for: latest)
            && !hasOwnedGeneration(for: latest, configuration: configuration, includeAttempts: true)
        if needsBrief {
            let now = Date.now
            // A confirmed recovery supersedes any older intent publication
            // that is still suspended for this chat, and a newer revision
            // supersedes this recovery.
            let intent = ResponseBriefPersistence.PendingRegeneration(
                chatID: chat.id,
                source: latest,
                length: length,
                createdAt: now,
                revision: recoveryEpoch
            )
            let accepted: Bool
            do {
                // Retain the latest-only recovery work together with its new
                // baseline so a relaunch behind accepted ownership still
                // performs exactly one latest submission.
                await awaitIntentPersistenceBarrier()
                guard isCurrentRecovery(chat: chat, epoch: recoveryEpoch) else { return }
                accepted = try await persistence.saveRecoveryIntent(intent, recordedAt: now)
            } catch {
                noteStorageFailure(error, chat: chat, sourceID: latest.id)
                return
            }
            // Rejected atomically because a newer revision already owns the
            // slot. Disabling the chat or starting a newer selection while the
            // save was suspended supersedes this recovery work; publishing it
            // would resume an obsolete request after re-enabling.
            guard accepted else { return }
            guard isCurrentRecovery(chat: chat, epoch: recoveryEpoch) else {
                await discardSupersededIntent(intent)
                return
            }
            pendingRegenerations[chat.id] = intent
            responseCursorByChatID[chat.id] = latest.responseID
            baselineAnchors[chat.id] = .init(
                chatID: chat.id,
                responseID: latest.responseID,
                identity: latest.identity,
                recordedAt: now
            )
            // An unsubmitted automatic job for this exact answer is superseded
            // by the durable recovery intent.
            pending.removeAll { job in
                job.source.chat.id == chat.id
                    && !job.isDeliberate
                    && areEquivalent(job.source, latest)
            }
            resumePendingRegeneration(for: chat, transport: transport)
            drain(transport: transport)
        } else {
            guard await advanceCursor(to: latest, expectingRevision: recoveryEpoch) else { return }
            guard isCurrentRecovery(chat: chat, epoch: recoveryEpoch) else { return }
        }
        clearObsoleteBaselineWarning(chatID: chat.id, latestSourceID: latest.id)
    }

    func retry(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        let unresolved = receipts.values
            .filter { areEquivalent($0.source, source) && $0.status != .settled }
            .max { $0.createdAt < $1.createdAt }
        let matchingIntent = pendingRegenerations[source.chat.id].flatMap {
            areEquivalent($0.source, source) ? $0 : nil
        }
        let replacement: Job? = matchingIntent.map { replacementJob(for: $0) }
        if let receipt = unresolved {
            states[source.chat.id] = ChatState(sourceID: receipt.source.id, phase: .idle)
            enqueue(job(for: receipt, force: true), transport: transport)
        } else if let replacement, receipts[replacement.generationID] == nil {
            // A durable replacement intent is the deliberate request the user
            // already queued. Retry resumes that exact submission instead of
            // creating an ordinary job that the intent would pay for again on
            // the next observation, poll, or relaunch.
            states[source.chat.id] = ChatState(sourceID: source.id, phase: .idle)
            enqueue(replacement, transport: transport)
        } else if receipts.values.contains(where: { areEquivalent($0.source, source) })
            || records.contains(where: { areEquivalent($0.source, source) }) {
            // A settled receipt or an existing brief cannot be replayed. Keep
            // an explicit regeneration path visible instead of clearing into
            // an empty idle rail the bounded enqueue would silently reject.
            states[source.chat.id] = ChatState(
                sourceID: source.id,
                phase: .regenerateNeeded("A previous brief request for this response already settled. Regenerate to create a fresh request.")
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
            // A receipt-backed presentation already identifies the exact
            // retryable owner; only explain waiting when no receipt exists yet.
            if !receipts.values.contains(where: {
                $0.source.chat.id == source.chat.id && $0.status != .settled
            }) {
                states[source.chat.id] = ChatState(
                    sourceID: source.id,
                    phase: .failed("Wait for the current response brief run to settle before regenerating.")
                )
            }
            return
        }
        if let matchingIntent = pendingRegenerations[source.chat.id].flatMap({
            areEquivalent($0.source, source) ? $0 : nil
        }) {
            let replacement = replacementJob(for: matchingIntent)
            if receipts[replacement.generationID] == nil {
                // A pending replacement is already the deliberate fresh request
                // for this answer. Dispatch it by identity instead of creating
                // an ordinary regeneration that would duplicate the paid work.
                states[source.chat.id] = ChatState(sourceID: source.id, phase: .idle)
                enqueue(replacement, transport: transport)
                return
            }
        }
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let job = Job(
            source: source,
            configuration: configuration,
            generationID: generationIdentity(for: source, configuration: configuration, length: length)
                + ":regenerate:" + UUID().uuidString,
            length: length,
            replacementKey: nil,
            replacementRevision: nil,
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
                        await disable(chat, transport: transport)
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

    /// Advances the durable baseline together with the identity evidence
    /// observed for that exact response. A crash between separate writes could
    /// otherwise strand the baseline after an identifier change. When a
    /// revision is supplied, the move is admitted atomically only while that
    /// revision is still the newest selection ordering for the chat, so a
    /// superseded recovery cannot move the baseline after a newer selection
    /// has been durably admitted.
    private func advanceCursor(
        to source: ResponseBriefSource,
        expectingRevision revision: Int? = nil
    ) async -> Bool {
        let recordedAt = Date.now
        do {
            let moved: Bool
            if let revision {
                moved = try await persistence.advanceCursor(
                    chatID: source.chat.id,
                    responseID: source.responseID,
                    anchorIdentity: source.identity,
                    recordedAt: recordedAt,
                    expectingRevision: revision
                )
            } else {
                try await persistence.advanceCursor(
                    chatID: source.chat.id,
                    responseID: source.responseID,
                    anchorIdentity: source.identity,
                    recordedAt: recordedAt
                )
                moved = true
            }
            guard moved else { return false }
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

    /// Clears an obsolete unmatched-baseline warning after reconciliation
    /// proved the saved baseline's continuity. Active operations and other
    /// failure presentations are left untouched.
    private func clearObsoleteBaselineWarning(chatID: String, latestSourceID: String) {
        guard operations[chatID] == nil,
              let state = states[chatID],
              case .baselineUnmatched = state.phase
        else { return }
        states[chatID] = ChatState(sourceID: latestSourceID, phase: .idle)
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
    /// only accepted relationships, plus durable aliases proven earlier. This
    /// is shared by generation ownership and the rail's selection, labeling,
    /// and original-response presentation so a reconciled live-to-persisted
    /// answer keeps one identity everywhere.
    func areEquivalent(_ lhs: ResponseBriefSource, _ rhs: ResponseBriefSource) -> Bool {
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

    /// Stores the single coalescible replacement intent for the chat and
    /// queues it. Accepted ownership is never rewritten; the replacement waits
    /// behind any unresolved receipt through the normal drain serialization.
    private func requestReplacement(
        for source: ResponseBriefSource,
        length: ResponseBriefLength,
        transport: ResponseBriefTransport
    ) async {
        // A new selection supersedes any older intent publication that is
        // still suspended, so the newest selection wins regardless of
        // persistence ordering. Advancing the epoch immediately also drops
        // older unowned replacement work before its own durable write is
        // awaited; an already-running unowned job is rejected at its
        // pre-receipt boundary by the captured revision.
        let epoch = supersedeOlderWork(for: source.chat.id)
        let intent = ResponseBriefPersistence.PendingRegeneration(
            chatID: source.chat.id,
            source: source,
            length: length,
            createdAt: .now,
            revision: epoch
        )
        let accepted: Bool
        do {
            await awaitIntentPersistenceBarrier()
            accepted = try await persistence.savePendingRegeneration(intent)
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
            return
        }
        // A newer revision already owns the slot when the atomic save was
        // rejected, so this selection never publishes over it. Disabling the
        // chat or selecting a newer length while the save was suspended
        // supersedes this intent too. Publishing it anyway would let a later
        // re-enable resume obsolete work.
        guard accepted, chatEpochs[source.chat.id] == epoch, isEnabled(source.chat) else {
            if accepted {
                await discardSupersededIntent(intent)
            }
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

    /// Advances the per-chat selection/cancellation epoch and returns the new
    /// value. Intent publications captured before this point are superseded.
    private func advanceChatEpoch(for chatID: String) -> Int {
        let next = (chatEpochs[chatID] ?? 0) + 1
        chatEpochs[chatID] = next
        return next
    }

    /// Advances the per-chat selection/cancellation epoch and immediately
    /// invalidates older unowned replacement jobs. The epoch moves before the
    /// newer selection's own durable write is awaited, so dropping the queued
    /// stale work here keeps an older preflight from surviving until the new
    /// intent becomes visible. Accepted ownership with a durable receipt is
    /// never discarded by this invalidation.
    private func supersedeOlderWork(for chatID: String) -> Int {
        let epoch = advanceChatEpoch(for: chatID)
        pending.removeAll { job in
            job.source.chat.id == chatID
                && job.replacementKey != nil
                && (job.replacementRevision ?? 0) < epoch
                && receipts[job.generationID] == nil
        }
        return epoch
    }

    /// True when an unowned replacement job no longer owns the chat's
    /// selection ordering. The captured revision is checked, not only the
    /// stored intent key: a newer selection can advance the epoch before its
    /// own durable write returns, leaving the previous intent stored while it
    /// is already superseded. A stale job must be rejected before durable
    /// receipt conversion so it can never create a paid submission.
    private func isSupersededReplacement(_ job: Job, chatID: String) -> Bool {
        guard let key = job.replacementKey else { return false }
        guard let intent = pendingRegenerations[chatID] else { return true }
        return intent.replacementKey != key
            || intent.revision != job.replacementRevision
            || chatEpochs[chatID] != job.replacementRevision
    }

    /// Whether a confirmed recovery still owns the chat's selection and
    /// cancellation ordering. A newer selection, disable/re-enable, or
    /// cancellation advances the epoch while the snapshot fetch is suspended,
    /// and an obsolete recovery must not move the baseline or publish work.
    private func isCurrentRecovery(_ chat: ResponseBriefChatIdentity, epoch: Int) -> Bool {
        chatEpochs[chat.id] == epoch && isEnabled(chat)
    }

    /// Removes a durable intent that lost a race with a disable or a newer
    /// selection and durably records the cancellation tombstone for its exact
    /// revision. A newer selection with a greater revision is preserved, and a
    /// delayed stale write for the discarded revision stays rejected instead of
    /// being restored by a post-hoc rewrite.
    private func discardSupersededIntent(
        _ intent: ResponseBriefPersistence.PendingRegeneration
    ) async {
        do {
            try await persistence.cancelPendingRegeneration(
                chatID: intent.chatID,
                revision: intent.revision
            )
        } catch {
            return
        }
        if pendingRegenerations[intent.chatID]?.replacementKey == intent.replacementKey {
            pendingRegenerations.removeValue(forKey: intent.chatID)
        }
    }

    /// Test-only suspension point around durable intent writes.
    private func awaitIntentPersistenceBarrier() async {
        if let barrier = intentPersistenceBarrier { await barrier() }
    }

    /// Resumes accepted ownership for this chat. A pending receipt is polled
    /// without another paid submission. A transport-uncertain receipt is never
    /// replayed automatically, but it stays visibly actionable so a relaunch or
    /// cancellation cannot strand its accepted run behind an idle chat.
    private func resumePendingReceipt(for chat: ResponseBriefChatIdentity, transport: ResponseBriefTransport) {
        // An active operation already owns any unresolved receipt for this chat.
        // Queuing that same receipt again would leave a stale replay behind if
        // cancellation settles it before the queued job reaches the front.
        guard operations[chat.id] == nil,
              let receipt = receipts.values
            .filter({ $0.source.chat.id == chat.id && $0.status != .settled })
            .min(by: { $0.createdAt < $1.createdAt })
        else { return }
        guard receipt.status == .pending else {
            presentUncertainOwnership(receipt, chatID: chat.id)
            return
        }
        enqueue(job(for: receipt), transport: transport)
    }

    /// Makes a transport-uncertain receipt actionable through the existing
    /// Retry control, which replays the exact captured request. Nothing is
    /// submitted automatically because the paid request may still be running.
    private func presentUncertainOwnership(
        _ receipt: ResponseBriefPersistence.Receipt,
        chatID: String
    ) {
        if let state = states[chatID] {
            switch state.phase {
            case .idle, .baselineUnmatched:
                break
            default:
                // Preserve an active operation or an existing explanation.
                return
            }
        }
        states[chatID] = ChatState(
            sourceID: receipt.source.id,
            phase: .failed("A response brief request may have been accepted. Retry replays its exact saved request without creating a new one."),
            runID: receipt.runID
        )
    }

    /// A user-confirmed recovery explicitly replays the oldest
    /// transport-uncertain receipt. Normal observation never does this because
    /// the accepted paid request may still be running.
    private func replayUncertainReceiptForRecovery(
        for chat: ResponseBriefChatIdentity,
        transport: ResponseBriefTransport
    ) {
        guard operations[chat.id] == nil,
              let receipt = receipts.values
            .filter({ $0.source.chat.id == chat.id && $0.status != .settled })
            .min(by: { $0.createdAt < $1.createdAt }),
              receipt.status == .needsExplicitRetry
        else { return }
        enqueue(job(for: receipt, force: true), transport: transport)
    }

    /// Builds the single dispatchable job for a durable replacement intent.
    /// Its identity is derived from the intent's captured key so a retry,
    /// support refresh, poll, user regeneration, or relaunch resumes exactly
    /// the same submission instead of creating an ordinary duplicate.
    private func replacementJob(
        for intent: ResponseBriefPersistence.PendingRegeneration
    ) -> Job {
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let key = intent.replacementKey
        let id = generationIdentity(for: intent.source, configuration: configuration, length: intent.length)
            + ":length:" + key
        return Job(
            source: intent.source,
            configuration: configuration,
            generationID: id,
            length: intent.length,
            replacementKey: key,
            replacementRevision: intent.revision,
            force: false,
            allowsNonPendingReceipt: false,
            isDeliberate: true
        )
    }

    /// Replays the durable replacement intent after relaunch. The job identity
    /// is derived from the intent's recorded timestamp, so resumption cannot
    /// create a second paid request for one selection.
    private func resumePendingRegeneration(
        for chat: ResponseBriefChatIdentity,
        transport: ResponseBriefTransport
    ) {
        guard isEnabled(chat), let intent = pendingRegenerations[chat.id] else { return }
        let job = replacementJob(for: intent)
        // Once a receipt exists the run owns the replacement; resuming it again
        // on every poll would only queue duplicate copies of the same request.
        guard receipts[job.generationID] == nil else { return }
        enqueue(job, transport: transport)
    }

    private func clearPendingRegeneration(key: String, revision: Int, chatID: String) async {
        guard pendingRegenerations[chatID]?.replacementKey == key,
              pendingRegenerations[chatID]?.revision == revision
        else { return }
        do {
            try await persistence.removePendingRegeneration(chatID: chatID, expectingKey: key)
        } catch {
            // The receipt now owns the work, so a lingering intent can only
            // deduplicate against that same request on the next load.
            return
        }
        if pendingRegenerations[chatID]?.replacementKey == key,
           pendingRegenerations[chatID]?.revision == revision {
            pendingRegenerations.removeValue(forKey: chatID)
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
            replacementRevision: nil,
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
                  intent.replacementKey == key,
                  intent.revision == job.replacementRevision,
                  chatEpochs[job.source.chat.id] == job.replacementRevision
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
        // Accepted ownership is reconciled before any fresh capability or
        // catalog preflight. A removed model, an unavailable catalog, or an
        // older companion must never strand an already-owned run or the
        // replacement waiting behind it: fetching a known run ID and replaying
        // a captured request do not depend on current machine support.
        if let saved = receipts[job.generationID] {
            if let key = job.replacementKey {
                await clearPendingRegeneration(
                    key: key,
                    revision: job.replacementRevision ?? 0,
                    chatID: chatID
                )
            }
            await completeGeneration(
                job,
                source: source,
                receipt: saved,
                deadline: deadline,
                transport: transport
            )
            return
        }
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

        states[chatID] = ChatState(sourceID: source.id, phase: .checkingSupport)
        await prepare(machineID: source.chat.machineID, transport: transport)
        // A newer selection can supersede an in-flight replacement while
        // capability and model preflight is suspended. Revalidate the captured
        // revision before creating durable ownership so a superseded selection
        // can never produce a paid submission even while the previous intent
        // is still the only one stored.
        if isSupersededReplacement(job, chatID: chatID) {
            states[chatID] = ChatState(sourceID: source.id, phase: .idle)
            return
        }
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

        let receipt: ResponseBriefPersistence.Receipt
        do {
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
            if let key = job.replacementKey {
                // Revalidate once more at the receipt boundary: the intent
                // must still be the captured revision, and the durable save
                // below admits that revision only while it is still the
                // newest selection ordering for this chat.
                guard !isSupersededReplacement(job, chatID: chatID) else {
                    states[chatID] = ChatState(sourceID: source.id, phase: .idle)
                    return
                }
                // The intent becomes the receipt in one atomic write, so a
                // selection that changed during the async preflight above
                // cannot leave a superseded paid request behind.
                guard try await persistence.commitReplacementReceipt(
                    receipt,
                    expecting: key,
                    revision: job.replacementRevision ?? 0
                ) else {
                    states[chatID] = ChatState(sourceID: source.id, phase: .idle)
                    return
                }
                if pendingRegenerations[chatID]?.replacementKey == key {
                    pendingRegenerations.removeValue(forKey: chatID)
                }
            } else {
                try await persistence.saveReceipt(receipt)
            }
            receipts[job.generationID] = receipt
            attemptedGenerationIDs.insert(job.generationID)
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

        await completeGeneration(
            job,
            source: source,
            receipt: receipt,
            deadline: deadline,
            transport: transport
        )
    }

    /// Finishes the paid phase of a generation whose durable receipt already
    /// exists or was just committed. A known run ID is fetched and a captured
    /// request is replayed without consulting current capability or catalog
    /// state, so accepted ownership always reconciles and never strands the
    /// replacement waiting behind it.
    private func completeGeneration(
        _ job: Job,
        source: ResponseBriefSource,
        receipt: ResponseBriefPersistence.Receipt,
        deadline: ContinuousClock.Instant,
        transport: ResponseBriefTransport
    ) async {
        let chatID = source.chat.id
        var receipt = receipt
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
            replacementRevision: nil,
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
