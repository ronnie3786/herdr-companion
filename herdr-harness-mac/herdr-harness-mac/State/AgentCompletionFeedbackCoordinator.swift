import Foundation

/// The Mac's single decision point for the completion cue.
///
/// Completion audio used to be produced independently by the mounted chat view
/// (a working → idle observer), by the window's fleet-status tracker, and by
/// Notification Center's default alert sound. The same logical completion could
/// therefore be heard twice, and a prompt submission could be mistaken for a
/// finish. Every source now reports evidence here instead:
///
/// - committed Pi settlement and committed Pi work starts from
///   `PiConversationStore`,
/// - successful fleet refreshes and fresh completion alerts from `HerdrAppModel`,
/// - terminal user-facing headless runs from `HeadlessAgentController`.
///
/// Evidence is scoped to a machine and a pane/terminal identity, with the Pi
/// session recorded per work episode, and each episode carries at most one
/// receipt. One completion normally produces two fleet observations - the
/// `working → done` transition and the done alert, published by the server at
/// different times - and both must share the single receipt. The coordinator
/// therefore tracks a separately acknowledged expectation per channel instead
/// of treating the second observation as a new completion. Pi starts carry the
/// committed event's server timestamp and cursor so a replay after a
/// disconnected stream can be ordered against a completion the fleet already
/// receipted, instead of replacing that receipt.
///
/// Reconciliation is exact and never truncated. A stalled fleet can deliver a
/// batch of already-heard completions at once (an acknowledged pane projects
/// as idle, so no `working → done` transition accompanies them), and dropping
/// the oldest obligations would make one of those delayed observations look
/// like a new completion. Every played completion therefore keeps its own
/// obligation until the matching observation consumes it, and a per-pane
/// ordering watermark collapses arbitrarily many duplicates whose committed
/// journal cursor is at or before - or whose server instant is strictly
/// before - an already-receipted completion.
///
/// The coordinator lives on `HerdrAppModel`, so completion ownership survives
/// the main window closing. `playback` is injectable so tests record requests
/// instead of playing audio.
@MainActor
final class AgentCompletionFeedbackCoordinator {
    /// One pane on one machine. `terminalID` separates a recreated pane, or a
    /// reused raw pane id, from the pane it replaced.
    struct PaneScope: Hashable, Sendable {
        let machineID: String
        let paneID: String
        let terminalID: String

        init(machineID: String, paneID: String, terminalID: String? = nil) {
            self.machineID = machineID
            self.paneID = paneID
            let trimmed = terminalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.terminalID = trimmed.isEmpty ? paneID : trimmed
        }
    }

    /// Identifiable provenance for one committed Pi lifecycle observation.
    ///
    /// `observedAt` is the envelope's `generated_at`, written by the same
    /// server clock that timestamps fleet pane activity and alerts, and
    /// `cursor` is the committed journal cursor. Together they identify the
    /// event without relying on a local elapsed-time window.
    struct PiWorkEvidence: Equatable, Sendable {
        let sessionID: String?
        let observedAt: String?
        let cursor: String?

        init(sessionID: String? = nil, observedAt: String? = nil, cursor: String? = nil) {
            self.sessionID = sessionID
            self.observedAt = observedAt
            self.cursor = cursor
        }

        static let none = PiWorkEvidence()

        var date: Date? {
            observedAt.flatMap(HerdrTimestamp.date(from:))
        }
    }

    /// One pane as a successful fleet refresh reported it.
    struct FleetObservation: Equatable, Sendable {
        let paneID: String
        let terminalID: String
        let status: AgentStatus
        /// `HerdrPane.episodeKey`: a status value alone does not identify a
        /// unique episode, because the same pane reads `.done` before and after
        /// it answers again.
        let episodeKey: String
        /// A completion alert this refresh reported for the first time for this
        /// pane. The server creates one alert per transition into `.done`.
        let newDoneAlertID: String?
        /// The fresh alert's server timestamp. A debounced pane snapshot can
        /// still report the previous done episode when the alert arrives, so
        /// an alert-only claim must record this instant rather than the stale
        /// `episodeKey`; otherwise a delayed Pi replay of the same completion
        /// looks like a newer turn and plays a second cue.
        let newDoneAlertCreatedAt: String?
        /// `HerdrPane.workingSince`: unlike `episodeKey`, it does not move on
        /// revision churn inside one work episode, so a changed value proves a
        /// new episode began.
        let workingSince: String?
        /// The pane's latest committed Pi journal cursor (`pi_semantic.cursor`)
        /// at this observation, used to order a replayed Pi start against the
        /// receipted completion.
        let piCursor: String?

        init(
            paneID: String,
            terminalID: String,
            status: AgentStatus,
            episodeKey: String,
            newDoneAlertID: String? = nil,
            newDoneAlertCreatedAt: String? = nil,
            workingSince: String? = nil,
            piCursor: String? = nil
        ) {
            self.paneID = paneID
            self.terminalID = terminalID
            self.status = status
            self.episodeKey = episodeKey
            self.newDoneAlertID = newDoneAlertID
            self.newDoneAlertCreatedAt = newDoneAlertCreatedAt
            self.workingSince = workingSince
            self.piCursor = piCursor
        }
    }

    /// A fresh `.done` alert whose pane was not reported as `.done` this time
    /// (the companion projects an acknowledged done pane as idle).
    struct DoneAlertObservation: Equatable, Sendable {
        let paneID: String
        let terminalID: String
        let alertID: String
        /// The alert's server timestamp, used as the completion time when the
        /// pane transition itself was not observed.
        let createdAt: String?

        init(
            paneID: String,
            terminalID: String,
            alertID: String,
            createdAt: String? = nil
        ) {
            self.paneID = paneID
            self.terminalID = terminalID
            self.alertID = alertID
            self.createdAt = createdAt
        }
    }

    typealias Playback = @MainActor () -> Void

    /// The audio sink. Production plays the explicit companion completion
    /// sound; tests substitute a recording closure.
    var playback: Playback

    /// One finished piece of work and the acknowledgements it still expects.
    ///
    /// The exact counters make the two server-side fleet observations of one
    /// completion idempotent:
    /// - `pendingPiAcknowledgements`: a committed Pi settlement already played,
    ///   so the first fleet evidence for the same run consumes one instead of
    ///   playing again.
    /// - `pendingAlertAcknowledgements`: a `working → done` transition already
    ///   played, so its alert consumes one instead of claiming a new completion
    ///   even when it arrives after a later turn started.
    /// - `pendingStatusAcknowledgements`: an alert already played, so the
    ///   matching done transition consumes one. A changed `workingSince`
    ///   discards these, because that transition can no longer arrive.
    ///
    /// These counts are never capped or truncated. Bounding them drops
    /// obligations that a later batched delivery still needs, which turns an
    /// already-heard completion into a replay.
    private struct Episode {
        var sessionID: String?
        var isComplete = false
        /// Server completion time of the receipted completion. A Pi work start
        /// at or before this instant belongs to the receipted episode, not to a
        /// newer turn.
        var completedAt: Date?
        /// The latest committed Pi journal cursor covered by the receipt. A Pi
        /// work start at or before this cursor is the receipted episode's own
        /// replay, even when its timestamp cannot be compared.
        var completedPiCursor: String?
        var pendingPiAcknowledgements = 0
        var pendingAlertAcknowledgements = 0
        var pendingStatusAcknowledgements = 0
    }

    /// Ordering evidence for the newest receipted completion on one pane,
    /// retained across later turns. An observation whose server instant is
    /// strictly before, or whose committed Pi cursor is at or before, this
    /// watermark describes work whose cue was already played, no matter how
    /// many refreshes were missed before it arrived. Unlike
    /// `Episode.completedAt`, it is not cleared when a new turn starts, so a
    /// snapshot restored from an older committed cursor can still be
    /// recognized as covered.
    ///
    /// The instant comparison is strict because the server timestamps are not
    /// guaranteed unique: two completions inside the same second share one, and
    /// the channel obligations above pair equal observations of one completion.
    /// Only a completion the stream itself cannot order needs the exact pairing.
    private struct ReceiptWatermark {
        var completedAt: Date?
        var piCursor: String?

        func covers(date: Date?, cursor: String?) -> Bool {
            if let cursorValue = cursor.flatMap(Int64.init),
               let receiptCursor = piCursor.flatMap(Int64.init) {
                return cursorValue <= receiptCursor
            }
            if let date, let completedAt {
                return date < completedAt
            }
            return false
        }

        /// Fleet alerts have their own server timestamp, but the pane's Pi
        /// cursor belongs to the *latest pane snapshot*, not necessarily that
        /// alert. Prefer the alert's instant when comparable: a stale pane
        /// cursor must not silence a newer alert, and an old alert must stay
        /// covered even if the pane has advanced since it was created.
        func coversFleet(date: Date?, paneCursor: String?) -> Bool {
            if let date, let completedAt { return date < completedAt }
            return covers(date: nil, cursor: paneCursor)
        }

        mutating func record(date: Date?, cursor: String?) {
            if let date {
                completedAt = completedAt.map { Swift.max($0, date) } ?? date
            }
            if let cursorValue = cursor.flatMap(Int64.init) {
                if let receiptCursor = piCursor.flatMap(Int64.init) {
                    if cursorValue > receiptCursor { piCursor = cursor }
                } else {
                    piCursor = cursor
                }
            }
        }
    }

    private struct PaneState {
        var episode: Episode?
        var fleetStatus: AgentStatus?
        var workingSince: String?
        var observedPiCursor: String?
        /// Ordering evidence for the newest played completion. Persists across
        /// episodes until a newer completion advances it.
        var receiptWatermark: ReceiptWatermark?
        var seenDoneEpisodeKeys: [String] = []
        var consumedDoneAlertIDs: [String] = []
    }

    private struct RunScope: Hashable {
        let machineID: String
        let runID: String
    }

    private enum FleetChannel {
        case status
        case alert
    }

    /// How many recent episode keys or alert ids one pane remembers. Bounded so
    /// a long-lived process cannot grow without limit while still outliving any
    /// realistic delayed duplicate observation. Acknowledgement counts are
    /// deliberately not bounded: ordering watermarks already collapse ordered
    /// duplicates, and an exact obligation is what lets an unordered batch of
    /// already-heard completions reconcile without replaying.
    private static let recentEvidenceLimit = 8
    /// How many finished-run receipts are retained before the oldest are
    /// pruned.
    private static let runReceiptLimit = 512

    private var paneStates: [PaneScope: PaneState] = [:]
    private var observedMachines: Set<String> = []
    private var completedRunReceipts: Set<RunScope> = []
    private var runReceiptOrder: [RunScope] = []

    init(playback: @escaping Playback = AgentCompletionFeedbackCoordinator.defaultPlayback) {
        self.playback = playback
    }

    /// The production cue. A test host never touches AppKit here: completion
    /// tests inject a recording sink, and unrelated suites that drive real
    /// model/controller completions must stay silent.
    static func defaultPlayback() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil
        else { return }
        HerdrMacFeedback.play(.completed)
    }

    /// Drops every receipt. Called at a confirmed connection identity boundary
    /// (credentials, configuration, or paired roster changed), where no prior
    /// observation can describe the new connection.
    func reset() {
        paneStates.removeAll()
        observedMachines.removeAll()
        completedRunReceipts.removeAll()
        runReceiptOrder.removeAll()
    }

    // MARK: Committed Pi lifecycle

    /// Committed work started: a published working phase, or a snapshot that
    /// restored an already-active run. Start evidence never plays a cue.
    func piWorkStarted(scope: PaneScope, evidence: PiWorkEvidence = .none) {
        var state = paneStates[scope] ?? PaneState()
        if var episode = state.episode {
            if !episode.isComplete,
               episode.sessionID == nil || evidence.sessionID == nil || episode.sessionID == evidence.sessionID {
                if episode.sessionID == nil { episode.sessionID = evidence.sessionID }
                state.episode = episode
                paneStates[scope] = state
                return
            }
            if isReplayedStart(episode: episode, evidence: evidence) {
                // The committed stream resumed and replayed the start of the
                // episode the fleet already receipted. Keep the receipt so the
                // replayed settlement cannot play a second cue.
                if episode.sessionID == nil { episode.sessionID = evidence.sessionID }
                state.episode = episode
                paneStates[scope] = state
                return
            }
            // A newer turn (or a different Pi session). Fleet acknowledgement
            // counters carry over so delayed evidence for the previous
            // completion consumes its slot instead of completing this turn.
            episode.sessionID = evidence.sessionID
            episode.isComplete = false
            episode.completedAt = nil
            episode.completedPiCursor = nil
            state.episode = episode
            paneStates[scope] = state
            return
        }
        state.episode = Episode(sessionID: evidence.sessionID)
        paneStates[scope] = state
    }

    /// A completed receipt absorbs a Pi start that the fleet already covered.
    /// A committed cursor at or before the receipt proves this is a replay.
    /// A fleet alert can precede its pane snapshot, however, leaving the pane
    /// cursor *behind* the run that alert describes. In that case a strictly
    /// earlier start instant also proves it was covered. Equal instants cannot
    /// order two turns when both cursors exist (server timestamp resolution is
    /// not guaranteed), so leave those to the channel acknowledgements.
    private func isReplayedStart(episode: Episode, evidence: PiWorkEvidence) -> Bool {
        guard episode.isComplete else { return false }
        if let cursor = evidence.cursor.flatMap(Int64.init),
           let completedCursor = episode.completedPiCursor.flatMap(Int64.init) {
            if cursor <= completedCursor { return true }
            if let startedAt = evidence.date, let completedAt = episode.completedAt {
                return startedAt < completedAt
            }
            return false
        }
        if let startedAt = evidence.date, let completedAt = episode.completedAt {
            return startedAt <= completedAt
        }
        return false
    }

    /// Committed Pi settlement: an `agent_settled` that the committed reducer
    /// applied while the published phase was working. Failure, cancellation,
    /// private recovery replay, and historical snapshots never reach this.
    func piWorkSettled(scope: PaneScope, evidence: PiWorkEvidence = .none) {
        var state = paneStates[scope] ?? PaneState()
        var episode = state.episode ?? Episode()
        if episode.isComplete {
            // The episode already owns a receipt: a delayed duplicate, or the
            // Pi evidence for a completion the fleet observed first.
            state.episode = episode
            paneStates[scope] = state
            return
        }
        if let sessionID = evidence.sessionID,
           let episodeSession = episode.sessionID,
           episodeSession != sessionID {
            // Settlement for an earlier session must not complete newer work.
            state.episode = episode
            paneStates[scope] = state
            return
        }
        // A settlement the watermark already covers is an out-of-order replay
        // of work whose cue was already played, never a new turn.
        if state.receiptWatermark?.covers(date: evidence.date, cursor: evidence.cursor) == true {
            state.episode = episode
            paneStates[scope] = state
            return
        }
        if episode.sessionID == nil { episode.sessionID = evidence.sessionID }
        episode.isComplete = true
        if let completedAt = evidence.date { episode.completedAt = completedAt }
        if let cursor = evidence.cursor { episode.completedPiCursor = cursor }
        episode.pendingPiAcknowledgements += 1
        var watermark = state.receiptWatermark ?? ReceiptWatermark()
        watermark.record(date: evidence.date, cursor: evidence.cursor)
        state.receiptWatermark = watermark
        state.episode = episode
        paneStates[scope] = state
        playback()
    }

    // MARK: Fleet observations

    /// One successful refresh for one machine. The first observation of a
    /// machine, and every observation after an identity reset, seeds the
    /// baseline without playing: an already-finished result found at startup
    /// is history, not news.
    func observeFleet(
        machineID: String,
        panes: [FleetObservation],
        doneAlerts: [DoneAlertObservation]
    ) {
        let isBaseline = !observedMachines.contains(machineID)
        observedMachines.insert(machineID)

        let observedScopes = Set(panes.map {
            PaneScope(machineID: machineID, paneID: $0.paneID, terminalID: $0.terminalID)
        })
        let staleScopes = paneStates.keys.filter {
            $0.machineID == machineID && !observedScopes.contains($0)
        }
        for scope in staleScopes {
            paneStates.removeValue(forKey: scope)
        }

        for pane in panes {
            observeFleetPane(pane, machineID: machineID, isBaseline: isBaseline)
        }
        for alert in doneAlerts {
            observeDoneAlert(alert, machineID: machineID, isBaseline: isBaseline)
        }
    }

    private func observeFleetPane(
        _ pane: FleetObservation,
        machineID: String,
        isBaseline: Bool
    ) {
        let scope = PaneScope(machineID: machineID, paneID: pane.paneID, terminalID: pane.terminalID)
        var state = paneStates[scope] ?? PaneState()
        let previousStatus = state.fleetStatus
        state.fleetStatus = pane.status
        if let piCursor = pane.piCursor { state.observedPiCursor = piCursor }

        guard pane.status == .done else {
            observeNonDoneStatus(pane, previousStatus: previousStatus, state: &state)
            paneStates[scope] = state
            return
        }
        // Leaving `working` ends the episode `workingSince` describes.
        state.workingSince = nil

        let freshEpisodeKey = !state.seenDoneEpisodeKeys.contains(pane.episodeKey)
        let freshAlert = pane.newDoneAlertID.map { !state.consumedDoneAlertIDs.contains($0) } ?? false
        appendBounded(pane.episodeKey, to: &state.seenDoneEpisodeKeys)
        if let alertID = pane.newDoneAlertID {
            appendBounded(alertID, to: &state.consumedDoneAlertIDs)
        }

        let statusEvidence = freshEpisodeKey && (previousStatus == .working || previousStatus == .blocked)
        // A repeated done status is never fresh evidence. The transition proves
        // work was in flight; a brand-new completion alert proves the companion
        // observed a transition even when no poll caught the working state.
        guard statusEvidence || freshAlert else {
            paneStates[scope] = state
            return
        }
        let shouldPlay: Bool
        if statusEvidence {
            shouldPlay = receiveFleetCompletion(
                &state,
                channel: .status,
                partnerIncluded: freshAlert,
                completedAt: pane.episodeKey,
                piCursor: state.observedPiCursor
            )
        } else {
            // Only the alert is new to the coordinator, and the pane snapshot
            // may still describe the previous done episode. The alert's own
            // server timestamp is the completion instant; the pane episode key
            // is only a fallback for evidence that carries no alert time.
            shouldPlay = receiveFleetCompletion(
                &state,
                channel: .alert,
                partnerIncluded: false,
                completedAt: pane.newDoneAlertCreatedAt ?? pane.episodeKey,
                piCursor: state.observedPiCursor
            )
        }
        paneStates[scope] = state
        if shouldPlay && !isBaseline { playback() }
    }

    /// Tracks work-episode boundaries without claiming a completion. A new
    /// `workingSince` discards alert-claimed status acknowledgements whose done
    /// transition was superseded, so they cannot silence the new episode.
    private func observeNonDoneStatus(
        _ pane: FleetObservation,
        previousStatus: AgentStatus?,
        state: inout PaneState
    ) {
        guard pane.status == .working else {
            state.workingSince = nil
            return
        }
        let newEpisode: Bool
        if let workingSince = pane.workingSince {
            newEpisode = state.workingSince != workingSince
            state.workingSince = workingSince
        } else {
            newEpisode = previousStatus != .working
        }
        if newEpisode, state.episode != nil {
            state.episode?.pendingStatusAcknowledgements = 0
        }
    }

    private func observeDoneAlert(
        _ alert: DoneAlertObservation,
        machineID: String,
        isBaseline: Bool
    ) {
        let scope = PaneScope(machineID: machineID, paneID: alert.paneID, terminalID: alert.terminalID)
        var state = paneStates[scope] ?? PaneState()
        guard !state.consumedDoneAlertIDs.contains(alert.alertID) else {
            paneStates[scope] = state
            return
        }
        appendBounded(alert.alertID, to: &state.consumedDoneAlertIDs)
        // Consume the evidence even while seeding a baseline; only a later
        // observation may play the receipt.
        let shouldPlay = receiveFleetCompletion(
            &state,
            channel: .alert,
            partnerIncluded: false,
            completedAt: alert.createdAt,
            piCursor: state.observedPiCursor
        )
        paneStates[scope] = state
        if shouldPlay && !isBaseline { playback() }
    }

    /// Applies one piece of fresh fleet completion evidence to a pane. The
    /// caller has already recorded the evidence itself, so a replayed
    /// observation cannot reach this again. Returns whether the cue should
    /// play; a pending acknowledgement consumes the evidence instead.
    private func receiveFleetCompletion(
        _ state: inout PaneState,
        channel: FleetChannel,
        partnerIncluded: Bool,
        completedAt: String?,
        piCursor: String?
    ) -> Bool {
        var episode = state.episode ?? Episode()
        let observationDate = completedAt.flatMap(HerdrTimestamp.date(from:))

        // Covered by the newest receipted completion: a delayed duplicate,
        // however many refreshes were missed before it arrived. Consume the
        // still-open obligation when there is one so a later genuine turn is
        // not mistaken for this completion's partner.
        if state.receiptWatermark?.coversFleet(date: observationDate, paneCursor: piCursor) == true {
            consumeDuplicateAcknowledgement(&state, channel: channel, partnerIncluded: partnerIncluded)
            return false
        }

        // The matching observation for a completion already receipted through
        // the other fleet channel: consume it without claiming a new episode.
        switch channel {
        case .status where episode.pendingStatusAcknowledgements > 0:
            episode.pendingStatusAcknowledgements -= 1
            state.episode = episode
            return false
        case .alert where episode.pendingAlertAcknowledgements > 0:
            episode.pendingAlertAcknowledgements -= 1
            state.episode = episode
            return false
        default:
            break
        }

        // The committed Pi settlement already played for this run.
        if episode.pendingPiAcknowledgements > 0 {
            episode.pendingPiAcknowledgements -= 1
            if !partnerIncluded {
                recordExpectation(for: channel, in: &episode)
            }
            state.episode = episode
            return false
        }

        // First evidence for this completion. Record the other channel's
        // expectation unless it arrived in the same refresh.
        episode.isComplete = true
        if let observationDate { episode.completedAt = observationDate }
        if let piCursor { episode.completedPiCursor = piCursor }
        if !partnerIncluded {
            recordExpectation(for: channel, in: &episode)
        }
        var watermark = state.receiptWatermark ?? ReceiptWatermark()
        watermark.record(date: observationDate, cursor: piCursor)
        state.receiptWatermark = watermark
        state.episode = episode
        return true
    }

    /// Consumes the open obligation a delayed duplicate would otherwise leave
    /// behind. Without this, a batch of already-heard completions arriving
    /// after the matching channel stopped observing would make the next
    /// genuine turn look like an old partner and stay silent.
    private func consumeDuplicateAcknowledgement(
        _ state: inout PaneState,
        channel: FleetChannel,
        partnerIncluded: Bool
    ) {
        var episode = state.episode ?? Episode()
        switch channel {
        case .status where episode.pendingStatusAcknowledgements > 0:
            episode.pendingStatusAcknowledgements -= 1
        case .alert where episode.pendingAlertAcknowledgements > 0:
            episode.pendingAlertAcknowledgements -= 1
        default:
            if episode.pendingPiAcknowledgements > 0 {
                episode.pendingPiAcknowledgements -= 1
                if !partnerIncluded {
                    recordExpectation(for: channel, in: &episode)
                }
            }
        }
        state.episode = episode
    }

    private func recordExpectation(for channel: FleetChannel, in episode: inout Episode) {
        switch channel {
        case .status:
            episode.pendingAlertAcknowledgements += 1
        case .alert:
            episode.pendingStatusAcknowledgements += 1
        }
    }

    // MARK: User-facing headless runs

    /// A terminal successful observation of a run the user asked for from this
    /// Mac: a completed or promoted HUD chat turn or Agent run, including one
    /// restored as active and one that finished before its first running poll.
    /// The durable run id makes repeated observations of the same run a no-op
    /// while a different machine or a later run stays eligible.
    func headlessRunFinished(machineID: String, runID: String) {
        let scope = RunScope(machineID: machineID, runID: runID)
        guard !completedRunReceipts.contains(scope) else { return }
        completedRunReceipts.insert(scope)
        runReceiptOrder.append(scope)
        let overflow = runReceiptOrder.count - Self.runReceiptLimit
        if overflow > 0 {
            for removed in runReceiptOrder.prefix(overflow) {
                completedRunReceipts.remove(removed)
            }
            runReceiptOrder.removeFirst(overflow)
        }
        playback()
    }

    private func appendBounded(_ value: String, to values: inout [String]) {
        values.removeAll { $0 == value }
        values.append(value)
        if values.count > Self.recentEvidenceLimit {
            values.removeFirst(values.count - Self.recentEvidenceLimit)
        }
    }
}
