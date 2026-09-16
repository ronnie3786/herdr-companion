import Foundation
import Observation
import os

enum PiStreamTransport: Equatable, Sendable {
    case liveStream
    case polling
}

private let piStreamLog = OSLog(subsystem: HerdrAppIdentity.bundleIdentifier, category: "pi-stream")

private struct PiRecoveryBoundary: Equatable, Sendable {
    let reason: String
    let expectedSessionID: String?
    let previousSessionID: String?
    let minimumSnapshotCursor: String?

    var permitsHistoryRewrite: Bool {
        ["backend_restarted", "session_tree", "session_compact", "session_changed", "session_lineage_changed"]
            .contains(reason)
    }
}

private enum PiRecoveryCause: Equatable, Sendable {
    case initial
    case reset(PiRecoveryBoundary)

    var permitsHistoryRewrite: Bool {
        guard case let .reset(boundary) = self else { return false }
        return boundary.permitsHistoryRewrite
    }
}

private struct PiPendingRecovery: Sendable {
    let generation: Int
    let cause: PiRecoveryCause
    let snapshot: PiConversationSnapshot?
}

private enum PiCommittedStreamResult: Sendable {
    case ended
    case recover(PiRecoveryCause)
    case superseded
}

private enum PiRehydrationResult: Sendable {
    case live
    case polling(PiConversationSnapshot)
    case restart(PiRecoveryCause)
    case superseded
    case stop
}

private enum PiPollingResult: Sendable {
    case live
    case superseded
    case stopped
}

private struct PiRecoveryExhausted: Error {}
private struct PiCandidateReset: Error {
    let cause: PiRecoveryCause
}

@MainActor
private final class PiRecoveryCandidateState {
    var reducer: PiConversationReducer
    var failedAttempts = 0

    init(reducer: PiConversationReducer) {
        self.reducer = reducer
    }
}

@MainActor
@Observable
final class PiConversationStore {
    private(set) var turns: [PiConversationTurn] = []
    private(set) var sessionID: String?
    private(set) var closedSessions: [PiClosedSession] = []
    private(set) var historyError: String?
    private(set) var isStartingNewSession = false
    private(set) var newSessionError: String?
    private(set) var sessionBoundaryRevision = 0
    @ObservationIgnored private var requestedSessionPredecessor: PiClosedSession?
    @ObservationIgnored private var newSessionRequestID: UUID?
    @ObservationIgnored var newSessionCommand: (@MainActor (HerdrPane) async throws -> Void)?
    @ObservationIgnored var newSessionPollInterval: Duration = .milliseconds(500)
    @ObservationIgnored var newSessionPollAttempts = 24
    @ObservationIgnored var sessionArchive = PiClosedSessionArchive()
    @ObservationIgnored private var archiveScope: String?
    @ObservationIgnored private var archiveIsReadable = true
    @ObservationIgnored private var unidentifiedSessionPredecessor: PiClosedSession?
    private(set) var pendingInteractions: [PiPendingInteraction] = []
    private(set) var phase: PiConversationPhase = .idle
    private(set) var compactionActivity: PiCompactionActivity?
    private(set) var connection: PiConversationConnection = .loading
    private(set) var revision = 0
    private(set) var structureRevision = 0
    private(set) var lastUserMessage: PiUserMessage?
    private(set) var userMessages: [PiUserMessage] = []
    private(set) var isTruncated = false
    private(set) var bridgeConnected = false
    private(set) var contextUsage: PiContextUsage?
    private(set) var sessionCost: PiSessionCost?
    private(set) var currentModel: PiModelIdentity?
    private(set) var availableModels: [PiAvailableModel] = []
    private(set) var isLoadingModels = false
    private(set) var isSettingModel = false
    private(set) var thinkingLevel: String?
    private(set) var isSettingThinkingLevel = false
    private(set) var modelCatalogError: String?
    private(set) var isModelSwitchingUnsupported = false
    private(set) var isSubmitting = false
    private(set) var isAborting = false
    private(set) var lastError: String?
    private(set) var commandNotice: String?
    private(set) var transport: PiStreamTransport = .liveStream

    @ObservationIgnored private var reducer = PiConversationReducer()
    @ObservationIgnored private var activeFollowID: UUID?
    @ObservationIgnored private var projectionGeneration = 0
    @ObservationIgnored private var hasLoadedSnapshot = false
    @ObservationIgnored private var coalescer = PiStreamCoalescer()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var streamingBlockIDs: Set<String> = []
    @ObservationIgnored private var activeOwnedWorkID: UUID?
    @ObservationIgnored private var activeOwnedWorkCancellation: (() -> Void)?
    @ObservationIgnored private var pendingRecovery: PiPendingRecovery?
    @ObservationIgnored private var recoveryDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var activeRecoveryDeadline: UUID?
    @ObservationIgnored private var expiredRecoveryDeadline: UUID?
    /// Internal test seams for deterministic snapshot and stream sequences.
    @ObservationIgnored var reconnectBackoffBase: Duration = .milliseconds(250)
    @ObservationIgnored var reconnectAttemptLimit = 8
    @ObservationIgnored var recoveryNoProgressTimeout: Duration = .seconds(15)
    @ObservationIgnored var connectedSnapshotPollInterval: Duration = .seconds(2)
    @ObservationIgnored var offlineSnapshotPollInterval: Duration = .seconds(5)
    @ObservationIgnored var snapshotProvider: (@MainActor (HerdrPane) async throws -> PiConversationSnapshot)?
    @ObservationIgnored var eventsProvider: (@MainActor (HerdrPane, String?) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>?)?
    @ObservationIgnored var recoveryProgress: (@MainActor (String?) -> Void)?
    @ObservationIgnored var publishObserver: (@MainActor (PiSessionCost?, Int) -> Void)?

    var hasContent: Bool {
        turns.contains(where: \.hasVisibleContent)
    }

    var isCompacting: Bool {
        compactionActivity != nil
    }

    var latestCompletedAssistantResponse: String? {
        turns.latestCompletedAssistantText
    }

    var hasUnconfirmedNewSession: Bool {
        newSessionError != nil && requestedSessionPredecessor != nil
    }

    var canSendCommands: Bool {
        bridgeConnected && connection.isConnected && !isStartingNewSession && !hasUnconfirmedNewSession
    }

    func submit(
        text: String,
        disposition: PiPromptDisposition,
        model: HerdrAppModel,
        pane: HerdrPane
    ) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSubmitting, compactionActivity == nil else { return false }
        guard canSendCommands else {
            lastError = "Pi is offline. Reconnect before sending a message."
            return false
        }
        let generation = projectionGeneration
        isSubmitting = true
        commandNotice = nil
        defer { if archiveScope == nil || archiveScope == pane.id { isSubmitting = false } }
        do {
            try await model.sendPiConversationPrompt(prompt, disposition: disposition, to: pane)
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = nil
            commandNotice = disposition == .followUp ? "Follow-up queued" : nil
            return true
        } catch {
            guard ownsOperation(generation, pane: pane) else { return false }
            commandNotice = nil
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func abort(model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard !isAborting, canSendCommands, compactionActivity == nil else { return false }
        let generation = projectionGeneration
        isAborting = true
        commandNotice = nil
        defer { if archiveScope == nil || archiveScope == pane.id { isAborting = false } }
        do {
            try await model.abortPiConversation(for: pane)
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = nil
            commandNotice = "Stop requested"
            return true
        } catch {
            guard ownsOperation(generation, pane: pane) else { return false }
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func setModel(_ candidate: PiAvailableModel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingModel, compactionActivity == nil else { return false }
        let generation = projectionGeneration
        isSettingModel = true
        commandNotice = nil
        defer { if archiveScope == nil || archiveScope == pane.id { isSettingModel = false } }
        do {
            try await model.setPiModel(provider: candidate.provider, modelID: candidate.modelID, for: pane)
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = nil
            commandNotice = "Model set to \(candidate.displayName)"
            return true
        } catch let APIError.server(status, _) where status == 501 {
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = "Model switching isn't supported by this Pi session"
            return false
        } catch {
            guard ownsOperation(generation, pane: pane) else { return false }
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func setThinkingLevel(_ level: PiThinkingLevel, model: HerdrAppModel, pane: HerdrPane) async -> Bool {
        guard canSendCommands, !isSettingThinkingLevel, compactionActivity == nil else { return false }
        let generation = projectionGeneration
        isSettingThinkingLevel = true
        commandNotice = nil
        defer { if archiveScope == nil || archiveScope == pane.id { isSettingThinkingLevel = false } }
        do {
            let effective = try await model.setPiThinkingLevel(level: level.rawValue, for: pane)
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = nil
            let effectiveDisplay = effective.flatMap { PiThinkingLevel(rawValue: $0)?.displayName ?? $0 }
                ?? level.displayName
            commandNotice = "Thinking set to \(effectiveDisplay)"
            return true
        } catch let APIError.server(status, _) where status == 501 {
            guard ownsOperation(generation, pane: pane) else { return false }
            lastError = "Thinking control isn't supported by this Pi session"
            return false
        } catch {
            guard ownsOperation(generation, pane: pane) else { return false }
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func retryLoadModels(model: HerdrAppModel, pane: HerdrPane) async {
        modelCatalogError = nil
        isModelSwitchingUnsupported = false
        await loadModels(model: model, pane: pane)
    }

    func respond(
        to interaction: PiPendingInteraction,
        response: PiInteractionResponseBody,
        model: HerdrAppModel,
        pane: HerdrPane
    ) async -> Bool {
        guard canSendCommands else {
            lastError = "Pi is offline. Reconnect before responding."
            return false
        }
        let generation = projectionGeneration
        do {
            try await model.respondToPiInteraction(
                id: interaction.id,
                response: response,
                in: pane
            )
            guard ownsOperation(generation, pane: pane) else { return false }
            reducer.removeInteraction(id: interaction.id)
            schedulePublish(.pendingInteraction)
            lastError = nil
            return true
        } catch {
            guard ownsOperation(generation, pane: pane) else { return false }
            guard !HerdrCancellation.isCancellation(error) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func clearCommandNotice() {
        commandNotice = nil
    }

    /// Consumes one live stream until it ends or the reducer requests an
    /// authoritative snapshot. Returning immediately on reset is important:
    /// healthy SSE connections are intentionally long-lived, so merely setting
    /// a flag would leave stale transcript state in place forever.
    func consume(
        _ events: AsyncThrowingStream<PiConversationStreamEvent, any Error>
    ) async throws -> Bool {
        defer { HerdrPerfDiagnostics.streamBacklog.reset(.pi) }
        for try await streamEvent in events {
            try Task.checkCancellation()
            HerdrPerfDiagnostics.streamBacklog.noteConsumed(.pi)
            switch streamEvent {
            case .activity:
                // An SSE heartbeat proves only that the harness is alive.
                // It says nothing about the extension socket behind it.
                continue
            case let .envelope(envelope):
                if reducer.rehydrationReason(for: envelope) != nil { return true }
                HerdrPerfDiagnostics.checkpoint("pi.envelope")
                let previousPhase = reducer.phase
                let previousCompactionActivity = reducer.compactionActivity
                let previousTurnCount = reducer.turns.count
                let previousPendingInteractions = reducer.pendingInteractions
                let previousBridgeConnected = reducer.bridgeConnected
                os_signpost(.begin, log: piStreamLog, name: "reducer.apply")
                let effect = reducer.apply(envelope)
                os_signpost(.end, log: piStreamLog, name: "reducer.apply")
                if effect == .needsSnapshot { return true }
                schedulePublish(
                    trigger(
                        for: effect,
                        previousPhase: previousPhase,
                        previousCompactionActivity: previousCompactionActivity,
                        previousTurnCount: previousTurnCount,
                        previousPendingInteractions: previousPendingInteractions,
                        previousBridgeConnected: previousBridgeConnected
                    )
                )
                let newConnection: PiConversationConnection = reducer.bridgeConnected ? .connected : .bridgeOffline
                let newError = reducer.bridgeConnected ? nil : "Pi is offline. The saved transcript is still available."
                if connection != newConnection { connection = newConnection }
                if lastError != newError { lastError = newError }
            }
        }
        return false
    }

    /// The menu action must capture the outgoing transcript *before* /new can
    /// clear it, and must not rely on an SSE notification arriving to refresh.
    func startNewSession(model: HerdrAppModel, pane: HerdrPane) async {
        guard !isStartingNewSession, !hasUnconfirmedNewSession, !isCompacting else { return }
        guard let previousID = sessionID, archiveScope == pane.id else {
            newSessionError = "Wait for the current Pi chat to connect before starting a new one."
            return
        }
        let requestID = UUID()
        newSessionRequestID = requestID
        requestedSessionPredecessor = PiClosedSession(id: previousID, turns: turns, wasTruncated: isTruncated)
        isStartingNewSession = true
        newSessionError = nil
        defer {
            if newSessionRequestID == requestID {
                newSessionRequestID = nil
                isStartingNewSession = false
                if requestedSessionPredecessor != nil, newSessionError == nil {
                    newSessionError = "Pi hasn't confirmed the new session yet. Check Terminal; chat will unlock once it is confirmed."
                }
            }
        }
        do {
            if let newSessionCommand { try await newSessionCommand(pane) }
            else { try await model.requestNewPiChat(in: pane) }
        } catch {
            guard newSessionRequestID == requestID else { return }
            requestedSessionPredecessor = nil
            newSessionError = "Couldn't start a new Pi chat: \(error.localizedDescription)"
            return
        }
        for _ in 0..<newSessionPollAttempts {
            guard !Task.isCancelled, newSessionRequestID == requestID else { return }
            if let sessionID, sessionID != previousID { return } // SSE already confirmed it.
            do {
                let snapshot = try await fetchSnapshot(model: model, pane: pane)
                guard !Task.isCancelled, newSessionRequestID == requestID else { return }
                if let sessionID, sessionID != previousID { return }
                let nextID = snapshot.session?.string(for: "id", "sessionId", "session_id") ?? snapshot.session?.stringValue
                if snapshot.available, snapshot.protocolInfo.name == "herdr.pi.semantic", snapshot.protocolInfo.version == 1,
                   let nextID, !nextID.isEmpty, nextID != previousID {
                    let cause = PiRecoveryCause.reset(PiRecoveryBoundary(
                        reason: "session_changed",
                        expectedSessionID: nextID,
                        previousSessionID: previousID,
                        minimumSnapshotCursor: nil
                    ))
                    if activeFollowID == nil,
                       commitPreparedRecoveryIfComplete(cause: cause, snapshot: snapshot) {
                        return
                    }
                    requestRecovery(cause: cause, snapshot: snapshot)
                    // The owned follow task performs the same finite-watermark
                    // transaction as every other authoritative session change.
                    // Wait for that commit rather than publishing this checkpoint
                    // directly and stranding a silent old SSE connection.
                    for _ in 0..<newSessionPollAttempts {
                        if sessionID == nextID { return }
                        guard !Task.isCancelled, newSessionRequestID == requestID else { return }
                        do { try await Task.sleep(for: newSessionPollInterval) } catch { return }
                    }
                    return
                }
            } catch {
                // Pi may briefly disconnect during /new. Keep the old chapter
                // intact and let the bounded poll or live stream confirm it.
            }
            do { try await Task.sleep(for: newSessionPollInterval) } catch { break }
        }
        guard newSessionRequestID == requestID else { return }
        newSessionError = "Pi hasn't confirmed the new session yet. Check Terminal; chat will unlock once it is confirmed."
    }

    func reset() {
        activeFollowID = nil
        activeOwnedWorkCancellation?()
        activeOwnedWorkID = nil
        activeOwnedWorkCancellation = nil
        pendingRecovery = nil
        cancelRecoveryDeadline()
        projectionGeneration &+= 1
        hasLoadedSnapshot = false
        newSessionRequestID = nil
        isStartingNewSession = false
        newSessionError = nil
        requestedSessionPredecessor = nil
        sessionBoundaryRevision = 0
        flushTask?.cancel()
        flushTask = nil
        for id in streamingBlockIDs {
            PiMarkdownDocumentCache.shared.evictStreaming(id: id)
            PiMarkdownInlineCache.shared.evictStreaming(id: id)
        }
        streamingBlockIDs = []
        coalescer = PiStreamCoalescer()
        reducer = PiConversationReducer()
        sessionID = nil
        closedSessions = []
        archiveScope = nil
        archiveIsReadable = true
        unidentifiedSessionPredecessor = nil
        historyError = nil
        turns = []
        pendingInteractions = []
        phase = .idle
        compactionActivity = nil
        connection = .loading
        revision &+= 1
        structureRevision = 0
        lastUserMessage = nil
        userMessages = []
        isTruncated = false
        bridgeConnected = false
        contextUsage = nil
        sessionCost = nil
        currentModel = nil
        availableModels = []
        isLoadingModels = false
        isSettingModel = false
        thinkingLevel = nil
        isSettingThinkingLevel = false
        modelCatalogError = nil
        isModelSwitchingUnsupported = false
        isSubmitting = false
        isAborting = false
        lastError = nil
        commandNotice = nil
        transport = .liveStream
    }

    private func snapshotContentChanged(
        from previous: PiConversationSnapshot,
        to current: PiConversationSnapshot
    ) -> Bool {
        previous.ok != current.ok
            || previous.protocolInfo != current.protocolInfo
            || previous.paneID != current.paneID
            || previous.available != current.available
            || previous.connected != current.connected
            || previous.session != current.session
            || previous.state != current.state
            || previous.entries != current.entries
            || previous.pendingInteractions != current.pendingInteractions
            || previous.cursor != current.cursor
            || previous.oldestCursor != current.oldestCursor
            || previous.truncated != current.truncated
    }

    private func fetchSnapshot(model: HerdrAppModel, pane: HerdrPane) async throws -> PiConversationSnapshot {
        if let snapshotProvider { return try await snapshotProvider(pane) }
        return try await model.fetchPiConversationSnapshot(for: pane)
    }

    private func fetchEvents(
        model: HerdrAppModel,
        pane: HerdrPane,
        after cursor: String?
    ) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>? {
        if let eventsProvider { return await eventsProvider(pane, cursor) }
        return await model.piConversationEvents(for: pane, after: cursor)
    }

    private func publishReducerState() {
        HerdrPerfDiagnostics.checkpoint("pi.publish")
        os_signpost(.event, log: piStreamLog, name: "publish")
        let previousStructureRevision = structureRevision
        retainClosedSession(nextSessionID: reducer.sessionID)
        reconcileStreamingCaches(with: reducer.turns)
        turns = reducer.turns
        sessionID = reducer.sessionID
        pendingInteractions = reducer.pendingInteractions
        structureRevision = reducer.structureRevision
        if structureRevision != previousStructureRevision {
            lastUserMessage = PiLastPrompt.lastUserMessage(in: turns)
            let messages = turns.compactMap(\.user)
            if messages != userMessages { userMessages = messages }
        }
        phase = reducer.phase
        compactionActivity = reducer.compactionActivity
        isTruncated = reducer.isTruncated
        bridgeConnected = reducer.bridgeConnected
        contextUsage = reducer.contextUsage
        sessionCost = reducer.sessionCost
        currentModel = reducer.currentModel
        thinkingLevel = reducer.thinkingLevel
        revision &+= 1
        publishObserver?(sessionCost, revision)
    }

    private func retainClosedSession(nextSessionID: String?) {
        // Only a confirmed non-nil identity change closes a chapter. Reconnect,
        // compaction and failed /new requests must never manufacture dividers.
        guard let nextSessionID else {
            if let sessionID {
                unidentifiedSessionPredecessor = PiClosedSession(id: sessionID, turns: turns, wasTruncated: isTruncated)
            }
            return
        }
        let previousID = sessionID ?? unidentifiedSessionPredecessor?.id
        guard let previousID, previousID != nextSessionID else {
            unidentifiedSessionPredecessor = nil
            return
        }
        let previous = requestedSessionPredecessor?.id == previousID ? requestedSessionPredecessor
            : sessionID == nil ? unidentifiedSessionPredecessor
            : PiClosedSession(id: previousID, turns: turns, wasTruncated: isTruncated)
        unidentifiedSessionPredecessor = nil
        guard let previous else { return }
        // A resumed session can close again with newer messages. Refresh that
        // chapter instead of duplicating its identity or keeping stale text.
        closedSessions.removeAll { $0.id == previous.id }
        closedSessions.append(previous)
        requestedSessionPredecessor = nil
        newSessionError = nil
        sessionBoundaryRevision &+= 1
        guard let archiveScope, archiveIsReadable else { return }
        do {
            try sessionArchive.save(closedSessions, scope: archiveScope)
            historyError = nil
        }
        catch { historyError = "Previous chat is visible here, but couldn't be saved on this Mac: \(error.localizedDescription)" }
    }

    private func reconcileStreamingCaches(with newTurns: [PiConversationTurn]) {
        var newlyStreamingIDs: Set<String> = []
        for turn in newTurns {
            for item in turn.items {
                switch item {
                case let .assistant(block):
                    if case .streaming = block.status { newlyStreamingIDs.insert(block.id) }
                case let .thinking(block):
                    if block.isStreaming { newlyStreamingIDs.insert(block.id) }
                case .tool, .notice:
                    break
                }
            }
        }
        for id in streamingBlockIDs where !newlyStreamingIDs.contains(id) {
            PiMarkdownDocumentCache.shared.evictStreaming(id: id)
            PiMarkdownInlineCache.shared.evictStreaming(id: id)
        }
        streamingBlockIDs = newlyStreamingIDs
    }

    private func trigger(
        for effect: PiConversationReducer.Effect,
        previousPhase: PiConversationPhase,
        previousCompactionActivity: PiCompactionActivity?,
        previousTurnCount: Int,
        previousPendingInteractions: [PiPendingInteraction],
        previousBridgeConnected: Bool
    ) -> PiStreamCoalescer.Trigger {
        switch effect {
        case .needsSnapshot:
            .streamReset
        case .completed:
            .turnCompletion
        case .interactionRequested:
            .pendingInteraction
        case .compactionChanged:
            .compactionChange
        case .failed:
            .phaseTransition
        case .none:
            if reducer.bridgeConnected != previousBridgeConnected {
                .connectionChange
            } else if reducer.phase != previousPhase {
                .phaseTransition
            } else if reducer.compactionActivity != previousCompactionActivity {
                .compactionChange
            } else if reducer.pendingInteractions != previousPendingInteractions {
                .pendingInteraction
            } else if reducer.turns.count > previousTurnCount {
                .turnBoundary
            } else {
                .delta
            }
        }
    }

    private func schedulePublish(_ trigger: PiStreamCoalescer.Trigger) {
        let clock = ContinuousClock()
        let generation = projectionGeneration
        switch coalescer.register(trigger, now: clock.now) {
        case .flushNow:
            flushTask?.cancel()
            flushTask = nil
            publishReducerState()
            coalescer.markFlushed()
        case let .coalesce(deadline):
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      self.projectionGeneration == generation
                else { return }
                // How late this task ran is a direct read of main-actor
                // congestion: the sleep ended on time, but the main thread was
                // still inside a layout pass. Widen the window accordingly.
                self.coalescer.noteFlushLateness(deadline.duration(to: clock.now))
                self.publishReducerState()
                self.coalescer.markFlushed()
                self.flushTask = nil
            }
        }
    }

    /// Follows one pane with a durable-cursor state machine. Ordinary transport
    /// reconnects resume the committed reducer; only semantic reset boundaries
    /// enter transactional snapshot recovery.
    func follow(model: HerdrAppModel, pane: HerdrPane) async {
        if let archiveScope, archiveScope != pane.id { reset() }
        if archiveScope != pane.id {
            archiveScope = pane.id
            do {
                closedSessions = try sessionArchive.load(scope: pane.id)
                archiveIsReadable = true
            } catch {
                closedSessions = []
                archiveIsReadable = false
                historyError = "Saved chat history couldn't be read. The original archive has been preserved."
            }
        }
        if pendingRecovery == nil {
            beginProjectionGeneration()
        } else {
            // A newly installed view task may replace the old follow task while
            // /new recovery is already queued. Preserve that authoritative
            // generation and only wake the old owned operation.
            activeOwnedWorkCancellation?()
        }
        let runID = UUID()
        activeFollowID = runID
        defer {
            if activeFollowID == runID {
                activeFollowID = nil
                activeOwnedWorkCancellation?()
                cancelRecoveryDeadline()
            }
        }
        connection = hasLoadedSnapshot ? .reconnecting(attempt: 0) : .loading
        lastError = nil

        var recovery: PiRecoveryCause? = hasLoadedSnapshot ? nil : .initial
        var preparedSnapshot: PiConversationSnapshot?
        var preparedGeneration: Int?
        var failedAttempts = 0
        var semanticRecoveryAttempts = 0
        var transportAttemptStartCursor = reducer.cursor

        while ownsFollow(runID, pane: pane) {
            if let request = pendingRecovery, request.generation == projectionGeneration {
                pendingRecovery = nil
                recovery = request.cause
                preparedSnapshot = request.snapshot
                preparedGeneration = request.generation
                semanticRecoveryAttempts = 0
            }
            do {
                if let cause = recovery {
                    switch try await rehydrateTransactionally(
                        cause: cause,
                        preparedSnapshot: preparedSnapshot,
                        preparedGeneration: preparedGeneration,
                        model: model,
                        pane: pane,
                        runID: runID
                    ) {
                    case .live:
                        semanticRecoveryAttempts = 0
                        recovery = nil
                        preparedSnapshot = nil
                        preparedGeneration = nil
                        failedAttempts = 0
                        if pane.piSemantic?.capabilities.listModels == true, availableModels.isEmpty {
                            Task { await loadModels(model: model, pane: pane) }
                        }
                    case let .polling(snapshot):
                        preparedSnapshot = nil
                        preparedGeneration = nil
                        switch await pollSnapshots(model: model, pane: pane, initialSnapshot: snapshot, runID: runID) {
                        case .live:
                            recovery = .initial
                            failedAttempts = 0
                            continue
                        case .superseded:
                            continue
                        case .stopped:
                            return
                        }
                    case let .restart(nextCause):
                        preparedSnapshot = nil
                        preparedGeneration = nil
                        semanticRecoveryAttempts += 1
                        guard semanticRecoveryAttempts <= reconnectAttemptLimit else {
                            pauseRecovery()
                            return
                        }
                        recovery = nextCause
                        let retryGeneration = projectionGeneration
                        let delay = retryDelay(attempt: semanticRecoveryAttempts)
                        do {
                            try await performOwnedWork { try await Task.sleep(for: delay) }
                        } catch is CancellationError where !Task.isCancelled && retryGeneration != projectionGeneration {
                            continue
                        }
                        continue
                    case .superseded:
                        continue
                    case .stop:
                        return
                    }
                }

                guard ownsFollow(runID, pane: pane) else { return }
                transport = .liveStream
                let generation = projectionGeneration
                transportAttemptStartCursor = reducer.cursor
                let requestedCursor = reducer.cursor
                let events: AsyncThrowingStream<PiConversationStreamEvent, any Error>?
                do {
                    events = try await performOwnedWork {
                        await self.fetchEvents(model: model, pane: pane, after: requestedCursor)
                    }
                } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                    continue
                }
                guard let events else { throw APIError.streamEnded }
                guard ownsFollow(runID, pane: pane), generation == projectionGeneration else { continue }
                connection = reducer.bridgeConnected ? .connected : .bridgeOffline
                lastError = reducer.bridgeConnected ? nil : "Pi is offline. The saved transcript is still available."

                let streamResult: PiCommittedStreamResult
                do {
                    streamResult = try await performOwnedWork {
                        try await self.consumeCommittedStream(events, pane: pane, runID: runID, generation: generation)
                    }
                } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                    continue
                }
                switch streamResult {
                case .ended:
                    if reducer.cursor != transportAttemptStartCursor {
                        failedAttempts = 0
                        semanticRecoveryAttempts = 0
                    }
                    throw APIError.streamEnded
                case let .recover(cause):
                    if reducer.cursor != transportAttemptStartCursor { semanticRecoveryAttempts = 0 }
                    semanticRecoveryAttempts += 1
                    guard semanticRecoveryAttempts <= reconnectAttemptLimit else {
                        pauseRecovery()
                        return
                    }
                    connection = .reconnecting(attempt: semanticRecoveryAttempts)
                    lastError = hasContent ? "Live updates paused. Reconnecting…" : nil
                    recovery = cause
                    let retryGeneration = projectionGeneration
                    let delay = retryDelay(attempt: semanticRecoveryAttempts)
                    do {
                        try await performOwnedWork { try await Task.sleep(for: delay) }
                    } catch is CancellationError where !Task.isCancelled && retryGeneration != projectionGeneration {
                        continue
                    }
                case .superseded:
                    continue
                }
            } catch is CancellationError {
                return
            } catch is PiRecoveryExhausted {
                pauseRecovery()
                return
            } catch {
                guard ownsFollow(runID, pane: pane), !HerdrCancellation.isCancellation(error) else { return }
                if isPermanentStreamError(error) {
                    connection = .unavailable
                    lastError = error.localizedDescription
                    return
                }
                if reducer.cursor != transportAttemptStartCursor { failedAttempts = 0 }
                failedAttempts = min(failedAttempts + 1, reconnectAttemptLimit)
                connection = .reconnecting(attempt: failedAttempts)
                lastError = hasContent ? "Live updates paused. Reconnecting…" : error.localizedDescription
                let retryGeneration = projectionGeneration
                let delay = retryDelay(attempt: failedAttempts)
                do {
                    try await performOwnedWork { try await Task.sleep(for: delay) }
                } catch is CancellationError where !Task.isCancelled && retryGeneration != projectionGeneration {
                    continue
                } catch {
                    return
                }
            }
        }
    }

    private func rehydrateTransactionally(
        cause: PiRecoveryCause,
        preparedSnapshot: PiConversationSnapshot?,
        preparedGeneration: Int?,
        model: HerdrAppModel,
        pane: HerdrPane,
        runID: UUID
    ) async throws -> PiRehydrationResult {
        let generation: Int
        if let preparedGeneration {
            guard preparedGeneration == projectionGeneration else { return .superseded }
            generation = preparedGeneration
        } else {
            beginProjectionGeneration()
            generation = projectionGeneration
        }

        let snapshot: PiConversationSnapshot
        if let preparedSnapshot {
            snapshot = preparedSnapshot
        } else {
            do {
                snapshot = try await performOwnedWork {
                    try await self.fetchSnapshot(model: model, pane: pane)
                }
            } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                return .superseded
            }
        }
        try Task.checkCancellation()
        guard ownsFollow(runID, pane: pane), generation == projectionGeneration else {
            return .superseded
        }
        guard snapshot.protocolInfo.name == "herdr.pi.semantic",
              snapshot.protocolInfo.version == 1,
              snapshot.available,
              snapshot.paneID.isEmpty || snapshot.paneID == pane.paneID
        else {
            connection = .unavailable
            lastError = "This Pi session does not expose a compatible native transcript."
            return .stop
        }

        // Copying the committed reducer keeps structural/item revision domains
        // monotonic across an atomic candidate swap.
        var candidate = reducer
        candidate.replace(with: snapshot)
        guard snapshotSatisfies(cause, candidate: candidate) else {
            return .restart(cause)
        }
        let retainsCommittedProjection = snapshotWouldRegressCommitted(candidate, cause: cause)

        guard snapshot.reportsContextUsage, snapshot.connected else {
            if !retainsCommittedProjection {
                commit(candidate, snapshot: snapshot, generation: generation)
            } else {
                connection = .bridgeOffline
                lastError = "Pi is offline. The saved transcript is still available."
            }
            return .polling(snapshot)
        }

        // A missing watermark identifies an older server. Keep a newer
        // same-session committed prefix, but cold checkpoints remain usable.
        guard var watermark = snapshot.latestCursor else {
            if !retainsCommittedProjection {
                commit(candidate, snapshot: snapshot, generation: generation)
            }
            return .live
        }

        if !cause.permitsHistoryRewrite,
           candidate.sessionID == reducer.sessionID,
           let visibleCursor = reducer.cursor,
           cursor(visibleCursor, isAfter: watermark) {
            watermark = visibleCursor
        }
        if let checkpoint = candidate.cursor, cursor(checkpoint, isAfter: watermark) {
            watermark = checkpoint
        }
        if cursor(candidate.cursor, reached: watermark) {
            commit(candidate, snapshot: snapshot, generation: generation)
            return .live
        }

        let catchUpWatermark = watermark
        let replay = PiRecoveryCandidateState(reducer: candidate)
        let deadlineToken = UUID()
        armRecoveryDeadline(deadlineToken, generation: generation)
        defer { cancelRecoveryDeadline(deadlineToken) }
        while ownsFollow(runID, pane: pane), generation == projectionGeneration {
            if expiredRecoveryDeadline == deadlineToken { throw PiRecoveryExhausted() }
            let requestedCursor = replay.reducer.cursor
            let events: AsyncThrowingStream<PiConversationStreamEvent, any Error>?
            do {
                events = try await performOwnedWork {
                    await self.fetchEvents(model: model, pane: pane, after: requestedCursor)
                }
            } catch is CancellationError where expiredRecoveryDeadline == deadlineToken {
                throw PiRecoveryExhausted()
            } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                return .superseded
            }
            guard let events else {
                replay.failedAttempts = min(replay.failedAttempts + 1, reconnectAttemptLimit)
                do {
                    try await performOwnedWork {
                        try await Task.sleep(for: self.retryDelay(attempt: replay.failedAttempts))
                    }
                } catch is CancellationError where expiredRecoveryDeadline == deadlineToken {
                    throw PiRecoveryExhausted()
                } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                    return .superseded
                }
                continue
            }
            do {
                try await performOwnedWork {
                    for try await streamEvent in events {
                        try Task.checkCancellation()
                        guard self.ownsFollow(runID, pane: pane), generation == self.projectionGeneration else {
                            throw CancellationError()
                        }
                        guard case let .envelope(envelope) = streamEvent else { continue }
                        try self.validate(envelope, for: pane)
                        if let reason = replay.reducer.rehydrationReason(for: envelope) {
                            throw PiCandidateReset(cause: self.recoveryCause(for: envelope, reason: reason, reducer: replay.reducer))
                        }
                        let previousCursor = replay.reducer.cursor
                        _ = replay.reducer.apply(envelope)
                        self.recoveryProgress?(replay.reducer.cursor)
                        if replay.reducer.cursor != previousCursor {
                            replay.failedAttempts = 0
                            self.armRecoveryDeadline(deadlineToken, generation: generation)
                        }
                        if self.cursor(replay.reducer.cursor, reached: catchUpWatermark) { return }
                    }
                    throw APIError.streamEnded
                }
                commit(replay.reducer, snapshot: snapshot, generation: generation)
                return .live
            } catch let reset as PiCandidateReset {
                return .restart(reset.cause)
            } catch is CancellationError where expiredRecoveryDeadline == deadlineToken {
                throw PiRecoveryExhausted()
            } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                return .superseded
            } catch {
                if isPermanentStreamError(error) { throw error }
                replay.failedAttempts = min(replay.failedAttempts + 1, reconnectAttemptLimit)
            }
            if expiredRecoveryDeadline == deadlineToken { throw PiRecoveryExhausted() }
            do {
                try await performOwnedWork {
                    try await Task.sleep(for: self.retryDelay(attempt: replay.failedAttempts))
                }
            } catch is CancellationError where expiredRecoveryDeadline == deadlineToken {
                throw PiRecoveryExhausted()
            } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                return .superseded
            }
        }
        return .superseded
    }

    private func consumeCommittedStream(
        _ events: AsyncThrowingStream<PiConversationStreamEvent, any Error>,
        pane: HerdrPane,
        runID: UUID,
        generation: Int
    ) async throws -> PiCommittedStreamResult {
        defer { HerdrPerfDiagnostics.streamBacklog.reset(.pi) }
        for try await streamEvent in events {
            try Task.checkCancellation()
            guard ownsFollow(runID, pane: pane), generation == projectionGeneration else {
                return .superseded
            }
            HerdrPerfDiagnostics.streamBacklog.noteConsumed(.pi)
            guard case let .envelope(envelope) = streamEvent else { continue }
            try validate(envelope, for: pane)
            if let reason = reducer.rehydrationReason(for: envelope) {
                return .recover(recoveryCause(for: envelope, reason: reason, reducer: reducer))
            }
            let previousPhase = reducer.phase
            let previousCompactionActivity = reducer.compactionActivity
            let previousTurnCount = reducer.turns.count
            let previousPendingInteractions = reducer.pendingInteractions
            let previousBridgeConnected = reducer.bridgeConnected
            os_signpost(.begin, log: piStreamLog, name: "reducer.apply")
            let effect = reducer.apply(envelope)
            os_signpost(.end, log: piStreamLog, name: "reducer.apply")
            schedulePublish(trigger(
                for: effect,
                previousPhase: previousPhase,
                previousCompactionActivity: previousCompactionActivity,
                previousTurnCount: previousTurnCount,
                previousPendingInteractions: previousPendingInteractions,
                previousBridgeConnected: previousBridgeConnected
            ))
            let nextConnection: PiConversationConnection = reducer.bridgeConnected ? .connected : .bridgeOffline
            let nextError = reducer.bridgeConnected ? nil : "Pi is offline. The saved transcript is still available."
            if connection != nextConnection { connection = nextConnection }
            if lastError != nextError { lastError = nextError }
        }
        return .ended
    }

    private func pollSnapshots(
        model: HerdrAppModel,
        pane: HerdrPane,
        initialSnapshot: PiConversationSnapshot,
        runID: UUID
    ) async -> PiPollingResult {
        transport = .polling
        var previous = initialSnapshot
        var failures = 0
        while ownsFollow(runID, pane: pane) {
            let generation = projectionGeneration
            do {
                let delay = previous.connected ? connectedSnapshotPollInterval : offlineSnapshotPollInterval
                let snapshot = try await performOwnedWork {
                    try await Task.sleep(for: delay)
                    return try await self.fetchSnapshot(model: model, pane: pane)
                }
                try Task.checkCancellation()
                guard ownsFollow(runID, pane: pane) else { return .stopped }
                guard generation == projectionGeneration else { return .superseded }
                guard snapshot.protocolInfo.name == "herdr.pi.semantic",
                      snapshot.protocolInfo.version == 1,
                      snapshot.available,
                      snapshot.paneID.isEmpty || snapshot.paneID == pane.paneID
                else {
                    connection = .unavailable
                    lastError = "This Pi session does not expose a compatible native transcript."
                    return .stopped
                }
                if snapshot.reportsContextUsage && snapshot.connected { return .live }
                if snapshotContentChanged(from: previous, to: snapshot) {
                    var candidate = reducer
                    candidate.replace(with: snapshot)
                    let sameSessionRegression = snapshotWouldRegressCommitted(candidate, cause: .initial)
                    if !sameSessionRegression {
                        beginProjectionGeneration()
                        commit(candidate, snapshot: snapshot, generation: projectionGeneration)
                    }
                    previous = snapshot
                }
                failures = 0
                connection = snapshot.connected ? .connected : .bridgeOffline
                lastError = snapshot.connected ? nil : "Pi is offline. The saved transcript is still available."
            } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                return .superseded
            } catch {
                guard !HerdrCancellation.isCancellation(error), ownsFollow(runID, pane: pane) else { return .stopped }
                if isPermanentStreamError(error) {
                    connection = .unavailable
                    lastError = error.localizedDescription
                    return .stopped
                }
                failures = min(failures + 1, reconnectAttemptLimit)
                connection = .reconnecting(attempt: failures)
                lastError = hasContent ? "Live updates paused. Reconnecting…" : error.localizedDescription
                let delay = retryDelay(attempt: failures)
                do {
                    try await performOwnedWork { try await Task.sleep(for: delay) }
                } catch is CancellationError where !Task.isCancelled && generation != projectionGeneration {
                    return .superseded
                } catch {
                    return .stopped
                }
            }
        }
        return .stopped
    }

    private func commitPreparedRecoveryIfComplete(
        cause: PiRecoveryCause,
        snapshot: PiConversationSnapshot
    ) -> Bool {
        var candidate = reducer
        candidate.replace(with: snapshot)
        guard snapshotSatisfies(cause, candidate: candidate),
              let watermark = snapshot.latestCursor,
              cursor(candidate.cursor, reached: watermark)
        else { return false }
        beginProjectionGeneration()
        commit(candidate, snapshot: snapshot, generation: projectionGeneration)
        return true
    }

    private func requestRecovery(cause: PiRecoveryCause, snapshot: PiConversationSnapshot? = nil) {
        beginProjectionGeneration()
        pendingRecovery = PiPendingRecovery(
            generation: projectionGeneration,
            cause: cause,
            snapshot: snapshot
        )
    }

    private func recoveryCause(
        for envelope: PiConversationEnvelope,
        reason: String,
        reducer: PiConversationReducer
    ) -> PiRecoveryCause {
        let currentSessionID = reducer.sessionID
        let normalizedType = envelope.eventType.replacingOccurrences(of: ".", with: "_")
        let explicitEventSessionID = envelope.event.string(for: "sessionId", "session_id")
            ?? (["session_start", "session_switch"].contains(normalizedType)
                ? envelope.event.string(for: "id")
                : nil)
        let incomingSessionID = [explicitEventSessionID, envelope.sessionID]
            .compactMap { $0 }
            .first { $0 != currentSessionID }
        let durableBoundary = ["session_tree", "session_compact"].contains(normalizedType)
            ? envelope.cursor
            : nil
        return .reset(PiRecoveryBoundary(
            reason: reason,
            expectedSessionID: incomingSessionID,
            previousSessionID: reason == "session_changed" ? currentSessionID : nil,
            minimumSnapshotCursor: durableBoundary
        ))
    }

    private func snapshotSatisfies(
        _ cause: PiRecoveryCause,
        candidate: PiConversationReducer
    ) -> Bool {
        guard case let .reset(boundary) = cause else { return true }
        if let expectedSessionID = boundary.expectedSessionID,
           candidate.sessionID != expectedSessionID {
            return false
        }
        if boundary.expectedSessionID == nil,
           let previousSessionID = boundary.previousSessionID,
           candidate.sessionID == previousSessionID || candidate.sessionID == nil {
            return false
        }
        if let minimum = boundary.minimumSnapshotCursor,
           !cursor(candidate.cursor, reached: minimum) {
            return false
        }
        return true
    }

    private func snapshotWouldRegressCommitted(
        _ candidate: PiConversationReducer,
        cause: PiRecoveryCause
    ) -> Bool {
        guard hasLoadedSnapshot,
              !cause.permitsHistoryRewrite,
              candidate.sessionID == reducer.sessionID,
              let visibleCursor = reducer.cursor
        else { return false }
        guard let checkpoint = candidate.cursor else { return true }
        return cursor(visibleCursor, isAfter: checkpoint)
    }

    private func performOwnedWork<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let workID = UUID()
        let task = Task { @MainActor in try await operation() }
        activeOwnedWorkID = workID
        activeOwnedWorkCancellation = { task.cancel() }
        defer {
            if activeOwnedWorkID == workID {
                activeOwnedWorkID = nil
                activeOwnedWorkCancellation = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func armRecoveryDeadline(_ token: UUID, generation: Int) {
        // A candidate may rearm only its own deadline. Intentional
        // supersession clears the active token through cancel(nil) first, so a
        // stale candidate can never cancel or replace newer recovery work.
        guard activeRecoveryDeadline == nil || activeRecoveryDeadline == token else { return }
        recoveryDeadlineTask?.cancel()
        activeRecoveryDeadline = token
        expiredRecoveryDeadline = nil
        let timeout = recoveryNoProgressTimeout
        recoveryDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, let self,
                  self.projectionGeneration == generation,
                  self.activeRecoveryDeadline == token
            else { return }
            self.expiredRecoveryDeadline = token
            self.activeOwnedWorkCancellation?()
        }
    }

    private func cancelRecoveryDeadline(_ token: UUID? = nil) {
        if let token, activeRecoveryDeadline != token { return }
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        activeRecoveryDeadline = nil
        if token == nil || expiredRecoveryDeadline == token { expiredRecoveryDeadline = nil }
    }

    private func pauseRecovery() {
        connection = .unavailable
        lastError = hasContent
            ? "Live updates paused. Reopen this chat to retry."
            : "Live transcript unavailable. Reopen this chat to retry."
    }

    private func commit(
        _ candidate: PiConversationReducer,
        snapshot: PiConversationSnapshot,
        generation: Int
    ) {
        guard generation == projectionGeneration else { return }
        cancelPendingPublish()
        reducer = candidate
        hasLoadedSnapshot = true
        publishReducerState()
        connection = snapshot.connected ? .connected : .bridgeOffline
        lastError = snapshot.connected ? nil : "Pi is offline. The saved transcript is still available."
    }

    private func beginProjectionGeneration() {
        let hadPendingPublish = flushTask != nil
        projectionGeneration &+= 1
        activeOwnedWorkCancellation?()
        cancelRecoveryDeadline()
        cancelPendingPublish()
        if hadPendingPublish { publishReducerState() }
    }

    private func cancelPendingPublish() {
        flushTask?.cancel()
        flushTask = nil
        coalescer = PiStreamCoalescer()
    }

    private func ownsFollow(_ runID: UUID, pane: HerdrPane) -> Bool {
        !Task.isCancelled && activeFollowID == runID && archiveScope == pane.id
    }

    private func ownsOperation(_ generation: Int, pane: HerdrPane) -> Bool {
        generation == projectionGeneration && (archiveScope == nil || archiveScope == pane.id)
    }

    private func validate(_ envelope: PiConversationEnvelope, for pane: HerdrPane) throws {
        guard envelope.protocolInfo.name == "herdr.pi.semantic",
              envelope.protocolInfo.version == 1,
              envelope.paneID.isEmpty || envelope.paneID == pane.paneID
        else { throw APIError.invalidResponse }
    }

    private func cursor(_ cursor: String?, reached watermark: String) -> Bool {
        guard let cursor else { return false }
        if let value = Int64(cursor), let target = Int64(watermark) { return value >= target }
        return cursor == watermark
    }

    private func cursor(_ lhs: String, isAfter rhs: String) -> Bool {
        if let left = Int64(lhs), let right = Int64(rhs) { return left > right }
        return false
    }

    private func retryDelay(attempt: Int) -> Duration {
        let exponent = max(0, min(attempt - 1, 5))
        return min(reconnectBackoffBase * (1 << exponent), .seconds(6))
    }

    private func isPermanentStreamError(_ error: any Error) -> Bool {
        if case APIError.invalidResponse = error { return true }
        if case let APIError.server(status, _) = error {
            return (400..<500).contains(status) && status != 408 && status != 429
        }
        return false
    }

    private func loadModels(model: HerdrAppModel, pane: HerdrPane) async {
        guard !isLoadingModels else { return }
        let generation = projectionGeneration
        isLoadingModels = true
        defer { if archiveScope == nil || archiveScope == pane.id { isLoadingModels = false } }
        do {
            let response = try await model.fetchPiModels(for: pane)
            guard ownsOperation(generation, pane: pane) else { return }
            availableModels = response.models
            if currentModel == nil { currentModel = response.current }
            modelCatalogError = nil
        } catch let APIError.server(status, _) where status == 501 {
            guard ownsOperation(generation, pane: pane) else { return }
            isModelSwitchingUnsupported = true
        } catch {
            guard ownsOperation(generation, pane: pane) else { return }
            guard !HerdrCancellation.isCancellation(error) else { return }
            modelCatalogError = "Couldn't load models"
        }
    }
}
