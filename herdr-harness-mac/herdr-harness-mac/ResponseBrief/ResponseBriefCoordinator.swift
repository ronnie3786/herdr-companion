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
        case alreadyConcise
        case regenerateNeeded(String)
        case unsupported
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
        let force: Bool
        let allowsNonPendingReceipt: Bool
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
    @ObservationIgnored private var latestSources: [String: ResponseBriefSource] = [:]
    @ObservationIgnored private var operations: [String: ActiveOperation] = [:]
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var isConnectionChanging = false
    private var supportedMachines: Set<String> = []
    private var unsupportedMachines: Set<String> = []
    @ObservationIgnored private var pollFailureCounts: [String: Int] = [:]
    @ObservationIgnored private var nextPollAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let globalConcurrencyLimit = 2
    @ObservationIgnored private let maximumQueuedPerChat = 8
    @ObservationIgnored var runPollDelay: Duration = .seconds(1)
    @ObservationIgnored var generationTimeout: Duration = .seconds(120)

    init(
        defaults: UserDefaults = .standard,
        persistence: ResponseBriefPersistence = ResponseBriefPersistence()
    ) {
        preferences = ResponseBriefPreferences(defaults: defaults)
        self.persistence = persistence
        selectedModel = preferences.model
        thinkingLevel = preferences.thinkingLevel
    }

    var enabledChats: [ResponseBriefChatIdentity] {
        _ = preferencesRevision
        return preferences.enabledChats
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
            $0.source.id == source.id
                && !$0.brief.conformsToConcisionPolicy(source: $0.source.text)
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
            && ResponseBriefConcisionPolicy(source: source.text).metrics.shouldGenerate
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

    func prepare(machineID: String, transport: ResponseBriefTransport) async {
        await load()
        guard storageError == nil, !unsupportedMachines.contains(machineID) else { return }
        do {
            if !supportedMachines.contains(machineID) {
                let capabilities = try await transport.capabilities(machineID)
                guard capabilities.profiles.contains("response-brief-v1") else {
                    unsupportedMachines.insert(machineID)
                    return
                }
                supportedMachines.insert(machineID)
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
        enqueue(source, transport: transport)
    }

    /// Ingests all eligible final answers in chronological order. The first
    /// observation establishes a baseline and generates only the newest answer;
    /// later snapshots queue every completion after the durable high-watermark.
    func observeSources(_ sources: [ResponseBriefSource], transport: ResponseBriefTransport) async {
        await load()
        guard let latest = sources.last, canDispatch(for: latest.chat) else { return }
        let chat = latest.chat
        latestSources[chat.id] = latest
        resumePendingReceipt(for: chat, transport: transport)
        drain(transport: transport)

        let candidates: ArraySlice<ResponseBriefSource>
        if let cursor = responseCursorByChatID[chat.id] {
            guard let cursorIndex = sources.lastIndex(where: { $0.responseID == cursor }) else {
                states[chat.id] = ChatState(
                    sourceID: latest.id,
                    phase: .failed("Some completed responses could not be matched to the saved brief baseline. No historical backfill was started.")
                )
                return
            }
            candidates = sources[sources.index(after: cursorIndex)...]
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
        settleIdlePresentation(for: chat)
        drain(transport: transport)
    }

    func retry(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        let configuredID = generationID(for: source)
        let configuredReceipt = receipts[configuredID].flatMap {
            $0.status == .settled ? nil : $0
        }
        let unresolvedSourceReceipt = receipts.values
            .filter { $0.source.id == source.id && $0.status != .settled }
            .max { $0.createdAt < $1.createdAt }
        let unresolvedChatReceipt = receipts.values
            .filter { $0.source.chat.id == source.chat.id && $0.status != .settled }
            .max { $0.createdAt < $1.createdAt }

        if let receipt = configuredReceipt ?? unresolvedSourceReceipt ?? unresolvedChatReceipt {
            let job = job(for: receipt, force: true)
            states[source.chat.id] = ChatState(sourceID: receipt.source.id, phase: .idle)
            enqueue(job, transport: transport)
        } else if receipts.values.contains(where: {
            $0.source.id == source.id && $0.status == .settled
        }) {
            states[source.chat.id] = ChatState(
                sourceID: source.id,
                phase: .regenerateNeeded("The previous result is settled and cannot be retried. Regenerate to create a fresh request.")
            )
        } else {
            states[source.chat.id] = ChatState(sourceID: source.id, phase: .idle)
            enqueue(source, transport: transport, force: true)
        }
    }

    func regenerate(_ source: ResponseBriefSource, transport: ResponseBriefTransport) async {
        await load()
        guard canDispatch(for: source.chat) else { return }
        guard ResponseBriefConcisionPolicy(source: source.text).metrics.shouldGenerate else {
            // A selected historical source must not replace the coordinator's
            // actual latest source. Legacy accepted work still owns its receipt
            // and must be reconciled before this no-op can settle.
            resumePendingReceipt(for: source.chat, transport: transport)
            drain(transport: transport)
            settleIdlePresentation(for: source.chat)
            return
        }
        let hasUnresolvedChatReceipt = receipts.values.contains {
            $0.source.chat.id == source.chat.id && $0.status != .settled
        }
        if operations[source.chat.id] != nil || hasUnresolvedChatReceipt {
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
            generationID: generationID(for: source, configuration: configuration)
                + ":regenerate:" + UUID().uuidString,
            force: true,
            allowsNonPendingReceipt: false
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

    private func advanceCursor(to source: ResponseBriefSource) async -> Bool {
        do {
            try await persistence.advanceCursor(chatID: source.chat.id, responseID: source.responseID)
            responseCursorByChatID[source.chat.id] = source.responseID
            return true
        } catch {
            noteStorageFailure(error, chat: source.chat, sourceID: source.id)
            return false
        }
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

    private func enqueue(
        _ source: ResponseBriefSource,
        transport: ResponseBriefTransport,
        force: Bool = false
    ) {
        guard !hasNonconformingBrief(for: source) else { return }
        guard ResponseBriefConcisionPolicy(source: source.text).metrics.shouldGenerate else {
            settleIdlePresentation(for: source.chat)
            return
        }
        let configuration = GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        let job = Job(
            source: source,
            configuration: configuration,
            generationID: generationID(for: source, configuration: configuration),
            force: force,
            allowsNonPendingReceipt: false
        )
        enqueue(job, transport: transport)
    }

    private func enqueue(_ job: Job, transport: ResponseBriefTransport) {
        let id = job.generationID
        if !job.force {
            if records.contains(where: { $0.id == id }) { return }
            if let receipt = receipts[id] {
                guard receipt.status == .pending else { return }
            } else if attemptedGenerationIDs.contains(id) {
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
            settleIdlePresentation(for: latestSources[chatID]?.chat)
        }
    }

    private func settleIdlePresentation(for chat: ResponseBriefChatIdentity?) {
        guard let chat,
              operations[chat.id] == nil,
              !receipts.values.contains(where: {
                  $0.source.chat.id == chat.id && $0.status != .settled
              }),
              let latest = latestSources[chat.id],
              !ResponseBriefConcisionPolicy(source: latest.text).metrics.shouldGenerate
        else { return }
        states[chat.id] = ChatState(sourceID: latest.id, phase: .alreadyConcise)
    }

    private func generate(_ job: Job, token: UUID, transport: ResponseBriefTransport) async {
        let source = job.source
        let chatID = source.chat.id
        let deadline = ContinuousClock.now.advanced(by: generationTimeout)
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
            if attemptedGenerationIDs.contains(job.generationID), !job.force { return }
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
        guard ContinuousClock.now < deadline else {
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
                receipt = saved
            } else {
                let request = try ResponseBriefRequestBuilder.request(
                    for: source,
                    model: job.configuration.model,
                    thinkingLevel: job.configuration.thinkingLevel
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
            if ContinuousClock.now >= deadline {
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
                brief = try ResponseBrief.decodeValidated(Data(response.utf8), source: source.text)
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
                createdAt: .now
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
            guard ContinuousClock.now < deadline else {
                var receipt = try requiredReceipt(for: source, runID: run.id)
                try await cancelForDeadline(receipt: &receipt, source: source, run: run, transport: transport)
                throw ResponseBriefCoordinatorError.timedOut
            }
            do {
                let requestedDelay = failures == 0 ? runPollDelay : .seconds(min(8, failures * 2))
                let remaining = ContinuousClock.now.duration(to: deadline)
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
            force: force,
            allowsNonPendingReceipt: force
        )
    }

    private func generationID(for source: ResponseBriefSource) -> String {
        generationID(
            for: source,
            configuration: GenerationConfiguration(model: selectedModel, thinkingLevel: thinkingLevel)
        )
    }

    private func generationID(for source: ResponseBriefSource, configuration: GenerationConfiguration) -> String {
        let material = [
            source.chat.machineID,
            source.chat.sessionID,
            source.responseID,
            source.sourceHash,
            String(ResponseBriefLimits.templateVersion),
            configuration.model ?? "default",
            configuration.thinkingLevel ?? "default",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
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
