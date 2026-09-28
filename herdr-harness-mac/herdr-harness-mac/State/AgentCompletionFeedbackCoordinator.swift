import Foundation

/// The Mac's single decision point for the completion cue.
///
/// Completion audio used to be produced independently by the mounted chat view
/// (a working → idle observer), by the window's fleet-status tracker, and by
/// Notification Center's default alert sound. The same logical completion could
/// therefore be heard twice, and a prompt submission could be mistaken for a
/// finish. Every source now reports evidence here instead:
///
/// - committed Pi settlement from `PiConversationStore`,
/// - successful fleet refreshes and fresh completion alerts from `HerdrAppModel`,
/// - terminal user-facing headless runs from `HeadlessAgentController`.
///
/// Evidence is scoped to a machine and a pane/terminal identity, with the Pi
/// session recorded per work episode, and each episode carries at most one
/// receipt, so the same completion observed by several sources still requests
/// exactly one playback. No global time window is involved: receipts are keyed
/// to actual identities and dropped only at identity boundaries (a new
/// connection generation, a recreated pane, or a pane that left the fleet).
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
    }

    /// A fresh `.done` alert whose pane was not reported as `.done` this time
    /// (the companion projects an acknowledged done pane as idle).
    struct DoneAlertObservation: Equatable, Sendable {
        let paneID: String
        let terminalID: String
        let alertID: String
    }

    typealias Playback = @MainActor () -> Void

    /// The audio sink. Production plays the explicit companion completion
    /// sound; tests substitute a recording closure.
    var playback: Playback

    /// One finished piece of work. `pendingFleetAcknowledgements` counts Pi
    /// settlements whose matching fleet observation has not arrived yet: both
    /// sources describe the same run, so the first fleet completion evidence
    /// after a settlement consumes one acknowledgement instead of playing a
    /// second cue.
    private struct Episode {
        var sessionID: String?
        var isComplete: Bool
        var pendingFleetAcknowledgements: Int
    }

    private struct PaneState {
        var episode: Episode?
        var fleetStatus: AgentStatus?
        var seenDoneEpisodeKeys: [String] = []
        var consumedDoneAlertIDs: [String] = []
    }

    private struct RunScope: Hashable {
        let machineID: String
        let runID: String
    }

    /// How many recent episode keys or alert ids one pane remembers. Bounded so
    /// a long-lived process cannot grow without limit while still outliving any
    /// realistic delayed duplicate observation.
    private static let recentEvidenceLimit = 8
    /// How many acknowledgement slots one pane can carry across a carry-over
    /// into a newer episode. More than this means the fleet path is not
    /// observing the pane, and suppressing every later completion would hide
    /// real work.
    private static let acknowledgementLimit = 2
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
    func piWorkStarted(scope: PaneScope, sessionID: String?) {
        var state = paneStates[scope] ?? PaneState()
        if var episode = state.episode,
           !episode.isComplete,
           episode.sessionID == nil || sessionID == nil || episode.sessionID == sessionID {
            if episode.sessionID == nil { episode.sessionID = sessionID }
            state.episode = episode
            paneStates[scope] = state
            return
        }
        // A newer turn (or a different Pi session) replaces the finished
        // episode. Any settlement still waiting for its fleet observation is
        // carried over so an old done result cannot finish this new turn.
        state.episode = Episode(
            sessionID: sessionID,
            isComplete: false,
            pendingFleetAcknowledgements: state.episode?.pendingFleetAcknowledgements ?? 0
        )
        paneStates[scope] = state
    }

    /// Committed Pi settlement: an `agent_settled` that the committed reducer
    /// applied while the published phase was working. Failure, cancellation,
    /// private recovery replay, and historical snapshots never reach this.
    func piWorkSettled(scope: PaneScope, sessionID: String?) {
        var state = paneStates[scope] ?? PaneState()
        if let episode = state.episode, episode.isComplete {
            // The episode already owns a receipt: a delayed duplicate.
            paneStates[scope] = state
            return
        }
        var episode = state.episode ?? Episode(
            sessionID: sessionID,
            isComplete: false,
            pendingFleetAcknowledgements: 0
        )
        if let sessionID, let episodeSession = episode.sessionID, episodeSession != sessionID {
            // Settlement for an earlier session must not complete newer work.
            paneStates[scope] = state
            return
        }
        if episode.sessionID == nil { episode.sessionID = sessionID }
        episode.isComplete = true
        episode.pendingFleetAcknowledgements = min(
            episode.pendingFleetAcknowledgements + 1,
            Self.acknowledgementLimit
        )
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

        guard pane.status == .done else {
            // Working, blocked, idle, and shell panes only update the
            // transition baseline. Starting work is silent.
            paneStates[scope] = state
            return
        }

        let freshEpisodeKey = !state.seenDoneEpisodeKeys.contains(pane.episodeKey)
        let freshAlert = pane.newDoneAlertID.map { !state.consumedDoneAlertIDs.contains($0) } ?? false
        appendBounded(pane.episodeKey, to: &state.seenDoneEpisodeKeys)
        if let alertID = pane.newDoneAlertID {
            appendBounded(alertID, to: &state.consumedDoneAlertIDs)
        }

        let transitionedFromWork = previousStatus == .working || previousStatus == .blocked
        // A repeated done status is never fresh evidence. The transition proves
        // work was in flight; a brand-new completion alert proves the companion
        // observed a transition even when no poll caught the working state.
        guard freshAlert || (freshEpisodeKey && transitionedFromWork) else {
            paneStates[scope] = state
            return
        }
        // Consume the evidence even while seeding a baseline, so a later
        // replayed observation cannot play it. Only a post-baseline
        // observation is allowed to make the receipt audible.
        let shouldPlay = claimFleetCompletion(&state)
        paneStates[scope] = state
        if shouldPlay && !isBaseline { playback() }
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
        let shouldPlay = claimFleetCompletion(&state)
        paneStates[scope] = state
        if shouldPlay && !isBaseline { playback() }
    }

    /// Applies one piece of fresh fleet completion evidence to a pane. The
    /// caller has already recorded the evidence itself, so a replayed
    /// observation cannot reach this again. Returns whether the cue should
    /// play; a pending Pi settlement consumes the evidence instead.
    private func claimFleetCompletion(_ state: inout PaneState) -> Bool {
        if var episode = state.episode {
            if episode.pendingFleetAcknowledgements > 0 {
                // The committed Pi settlement already played for this run.
                episode.pendingFleetAcknowledgements -= 1
                state.episode = episode
                return false
            }
            if !episode.isComplete {
                episode.isComplete = true
                state.episode = episode
                return true
            }
        }
        state.episode = Episode(
            sessionID: nil,
            isComplete: true,
            pendingFleetAcknowledgements: 0
        )
        return true
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
