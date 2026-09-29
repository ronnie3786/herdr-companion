import Foundation
import Testing
@testable import herdr_harness_mac

/// Records completion-cue playbacks instead of touching AppKit.
@MainActor
final class CompletionFeedbackRecorder {
    private(set) var count = 0

    func record() { count += 1 }
}

@Suite("Agent completion feedback coordinator")
@MainActor
struct AgentCompletionFeedbackTests {
    private let machine = "machine-a"
    private let pane = "w1:p1"
    private let terminal = "terminal-1"

    private func makeCoordinator() -> (AgentCompletionFeedbackCoordinator, CompletionFeedbackRecorder) {
        let recorder = CompletionFeedbackRecorder()
        let coordinator = AgentCompletionFeedbackCoordinator(playback: { recorder.record() })
        return (coordinator, recorder)
    }

    private func scope(_ machineID: String = "machine-a") -> AgentCompletionFeedbackCoordinator.PaneScope {
        AgentCompletionFeedbackCoordinator.PaneScope(
            machineID: machineID,
            paneID: pane,
            terminalID: terminal
        )
    }

    private func paneObservation(
        _ status: AgentStatus,
        episodeKey: String,
        newDoneAlertID: String? = nil,
        newDoneAlertCreatedAt: String? = nil,
        workingSince: String? = nil,
        piCursor: String? = nil,
        machineID: String = "machine-a",
        paneID: String = "w1:p1",
        terminalID: String = "terminal-1"
    ) -> AgentCompletionFeedbackCoordinator.FleetObservation {
        AgentCompletionFeedbackCoordinator.FleetObservation(
            paneID: paneID,
            terminalID: terminalID,
            status: status,
            episodeKey: episodeKey,
            newDoneAlertID: newDoneAlertID,
            newDoneAlertCreatedAt: newDoneAlertCreatedAt,
            workingSince: workingSince,
            piCursor: piCursor
        )
    }

    private func refresh(
        _ coordinator: AgentCompletionFeedbackCoordinator,
        _ panes: [AgentCompletionFeedbackCoordinator.FleetObservation],
        alerts: [AgentCompletionFeedbackCoordinator.DoneAlertObservation] = [],
        machineID: String = "machine-a"
    ) {
        coordinator.observeFleet(machineID: machineID, panes: panes, doneAlerts: alerts)
    }

    private func alert(
        _ id: String,
        createdAt: String? = nil,
        paneID: String = "w1:p1",
        terminalID: String = "terminal-1"
    ) -> AgentCompletionFeedbackCoordinator.DoneAlertObservation {
        AgentCompletionFeedbackCoordinator.DoneAlertObservation(
            paneID: paneID,
            terminalID: terminalID,
            alertID: id,
            createdAt: createdAt
        )
    }

    @Test("Prompt start and a historical done result stay silent")
    func submissionAndHistoryAreSilent() {
        let (coordinator, recorder) = makeCoordinator()
        // Startup baseline: a previous completed answer is displayed.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e1")])

        // The user submits; committed work starts with the previous done still
        // displayed and the revision churning.
        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))

        #expect(recorder.count == 0)
    }

    @Test("One committed settlement plays once per episode")
    func settlementPlaysOncePerTurn() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])

        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)

        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 2)
    }

    @Test("A settlement whose start was never published still plays once")
    func settlementWithoutPublishedStart() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)
    }

    @Test("Fleet completion after a committed settlement never double-plays")
    func fleetAfterSettlementIsSilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)

        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        // A later turn must remain independently eligible.
        refresh(coordinator, [paneObservation(.working, episodeKey: "e3")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e4")])
        #expect(recorder.count == 2)
    }

    @Test("Fleet completion before a committed settlement plays once")
    func settlementAfterFleetIsSilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)
    }

    @Test("Unmounted chats complete once per working transition")
    func fleetOnlyCompletion() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        // Repeated observations of the same done episode are duplicates.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        refresh(coordinator, [paneObservation(.working, episodeKey: "e3")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e4")])
        #expect(recorder.count == 2)
    }

    @Test("A fresh completion alert covers a run that finished before any running poll")
    func fastCompletionAlert() {
        let (coordinator, recorder) = makeCoordinator()
        // Baseline: the previous answer's alert is already known.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e0", newDoneAlertID: "alert-0")])
        #expect(recorder.count == 0)

        // The next run completes between polls: no working status, same
        // episode-key baseline, but a brand-new alert.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e1", newDoneAlertID: "alert-1")])
        #expect(recorder.count == 1)
        // A delayed duplicate of the same alert never plays again.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e1", newDoneAlertID: "alert-1")])
        #expect(recorder.count == 1)

        // A later run's alert is independent.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", newDoneAlertID: "alert-2")])
        #expect(recorder.count == 2)
    }

    @Test("A fresh alert keeps its own instant over a stale pane snapshot and cursor")
    func freshAlertInstantBeatsStalePaneSnapshot() {
        let (coordinator, recorder) = makeCoordinator()
        // Baseline: the previous answer is done at T0 and its alert is known.
        refresh(coordinator, [paneObservation(.done, episodeKey: "2030-01-01T00:00:00Z", piCursor: "1")])
        #expect(recorder.count == 0)

        // The new alert (T2) arrives while the debounced pane snapshot still
        // reports the previous done episode AND cursor at T0.
        refresh(coordinator, [paneObservation(
            .done,
            episodeKey: "2030-01-01T00:00:00Z",
            newDoneAlertID: "alert-1",
            newDoneAlertCreatedAt: "2030-01-01T00:00:20Z",
            piCursor: "1"
        )])
        #expect(recorder.count == 1)

        // The committed stream resumes late. Its start's cursor is newer than
        // the stale pane's cursor, but its instant predates the alert; this is
        // still the already-receipted turn, not a new one.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:10Z", cursor: "2")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:30Z", cursor: "3")
        )
        #expect(recorder.count == 1)

        // A genuinely later turn is newer than the receipt and plays once.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:00Z", cursor: "4")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:05Z", cursor: "5")
        )
        #expect(recorder.count == 2)
    }

    @Test("A fresh alert whose pane is projected idle shares the same receipt")
    func freshAlertOwnsProjectedIdleCompletion() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        // The user acknowledged quickly, so the companion projects the pane as
        // idle while the new completion alert still reports the transition.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e1")], alerts: [
            alert("alert-1")
        ])
        #expect(recorder.count == 1)

        // The same alert observed again is not a second completion.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e1")], alerts: [
            alert("alert-1")
        ])
        #expect(recorder.count == 1)

        // A new work episode discards the status acknowledgement the projected
        // idle can never deliver, so the next completion still plays.
        refresh(coordinator, [paneObservation(
            .working,
            episodeKey: "e2",
            workingSince: "2030-01-01T00:01:00Z"
        )])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e3")])
        #expect(recorder.count == 2)
    }

    @Test("An alert before its debounced done transition shares one receipt")
    func alertBeforeDoneTransitionIsSilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        // The server publishes the alert first; the cached pane still reads
        // working until the next refresh.
        refresh(coordinator, [
            paneObservation(.working, episodeKey: "e1", workingSince: "2030-01-01T00:00:00Z")
        ], alerts: [
            alert("alert-1", createdAt: "2030-01-01T00:00:01Z")
        ])
        #expect(recorder.count == 1)

        // The matching done transition is the same completion, not a new one.
        refresh(coordinator, [paneObservation(.done, episodeKey: "2030-01-01T00:00:02Z")])
        #expect(recorder.count == 1)

        // A genuinely later turn plays its own single cue.
        refresh(coordinator, [paneObservation(
            .working,
            episodeKey: "2030-01-01T00:01:00Z",
            workingSince: "2030-01-01T00:01:00Z"
        )])
        refresh(coordinator, [paneObservation(.done, episodeKey: "2030-01-01T00:01:05Z")])
        #expect(recorder.count == 2)
    }

    @Test("A delayed alert never completes a newer Pi turn")
    func delayedAlertAfterNewTurnIsSilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        // The next turn starts before the old completion's alert arrives.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:00Z")
        )
        refresh(coordinator, [
            paneObservation(.working, episodeKey: "e3", workingSince: "2030-01-01T00:01:00Z")
        ], alerts: [
            alert("alert-1", createdAt: "2030-01-01T00:00:02Z")
        ])
        #expect(recorder.count == 1)

        // The alert was the previous completion's partner, so the new turn
        // still cues its own settlement exactly once.
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:05Z")
        )
        #expect(recorder.count == 2)

        // The delayed alert repeated is still silent.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e4")], alerts: [
            alert("alert-1", createdAt: "2030-01-01T00:00:02Z")
        ])
        #expect(recorder.count == 2)
    }

    @Test("A fleet-first receipt survives a delayed Pi start and settlement replay")
    func fleetReceiptSurvivesDelayedPiReplay() {
        let (coordinator, recorder) = makeCoordinator()
        let completedAt = "2030-01-01T00:00:10Z"
        refresh(coordinator, [paneObservation(.working, episodeKey: "2030-01-01T00:00:00Z")])
        refresh(coordinator, [paneObservation(.done, episodeKey: completedAt)])
        #expect(recorder.count == 1)

        // The stream resumes and replays the already-completed turn. Both
        // events predate the fleet completion evidence, so the receipt stays.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:05Z", cursor: "10")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:06Z", cursor: "11")
        )
        #expect(recorder.count == 1)

        // A genuinely later turn is newer than the receipt and plays once.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:00Z", cursor: "20")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:05Z", cursor: "21")
        )
        #expect(recorder.count == 2)
    }

    @Test("The same delayed Pi replay after a fleet alert claim stays silent")
    func delayedPiReplayAfterAlertClaim() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e1")], alerts: [
            alert("alert-1", createdAt: "2030-01-01T00:00:10Z")
        ])
        #expect(recorder.count == 1)

        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:05Z")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:00:06Z")
        )
        #expect(recorder.count == 1)

        // A later turn still cues.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:00Z")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", observedAt: "2030-01-01T00:01:05Z")
        )
        #expect(recorder.count == 2)
    }

    @Test("A fleet-first receipt survives a delayed Pi replay by journal cursor")
    func fleetReceiptSurvivesDelayedPiReplayByCursor() {
        let (coordinator, recorder) = makeCoordinator()
        // The completion timestamp is not parseable, so only the committed
        // journal cursor can prove the delayed start belongs to this receipt.
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", piCursor: "11")])
        #expect(recorder.count == 1)

        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", cursor: "10")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", cursor: "11")
        )
        #expect(recorder.count == 1)

        // A later turn past the receipted watermark still cues once.
        coordinator.piWorkStarted(
            scope: scope(),
            evidence: .init(sessionID: "s1", cursor: "20")
        )
        coordinator.piWorkSettled(
            scope: scope(),
            evidence: .init(sessionID: "s1", cursor: "21")
        )
        #expect(recorder.count == 2)
    }

    @Test("Two machines with identical raw pane ids stay independent")
    func machinesAreScoped() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")], machineID: "machine-a")
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")], machineID: "machine-b")
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")], machineID: "machine-a")
        #expect(recorder.count == 1)
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")], machineID: "machine-b")
        #expect(recorder.count == 2)
    }

    @Test("A new connection generation re-seeds the baseline silently")
    func connectionResetBaselines() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        coordinator.reset()
        // The first observation after an identity boundary is history.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", newDoneAlertID: "alert-1")])
        #expect(recorder.count == 1)

        refresh(coordinator, [paneObservation(.working, episodeKey: "e3")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e4")])
        #expect(recorder.count == 2)
    }

    @Test("Recreated panes and reused ids do not inherit a receipt")
    func terminalIdentityBoundsReceipts() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        // A different terminal with the same raw pane id is a different pane.
        refresh(coordinator, [paneObservation(
            .working,
            episodeKey: "e3",
            terminalID: "terminal-2"
        )])
        refresh(coordinator, [paneObservation(
            .done,
            episodeKey: "e4",
            terminalID: "terminal-2"
        )])
        #expect(recorder.count == 2)
    }

    @Test("Terminal user-facing runs play once per durable run id")
    func headlessRunReceipts() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.headlessRunFinished(machineID: machine, runID: "run-1")
        coordinator.headlessRunFinished(machineID: machine, runID: "run-1")
        #expect(recorder.count == 1)

        // A promoted observation of the same run is not a second cue.
        coordinator.headlessRunFinished(machineID: machine, runID: "run-1")
        #expect(recorder.count == 1)

        // A continuation and the same raw id on another machine are new runs.
        coordinator.headlessRunFinished(machineID: machine, runID: "run-2")
        coordinator.headlessRunFinished(machineID: "machine-b", runID: "run-1")
        #expect(recorder.count == 3)
    }

    @Test("A delayed duplicate observation of one completion never plays twice")
    func delayedDuplicatesStaySilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", newDoneAlertID: "alert-1")])
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)

        // Every later replay of the same evidence is a duplicate.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", newDoneAlertID: "alert-1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 1)
    }

    @Test("Batched delayed alerts for ordered Pi turns never replay")
    func orderedBatchedAlertsStaySilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])

        // Three turns settle while the fleet is stalled. Ordering evidence
        // makes every heard completion independently identifiable.
        let timestamps = [
            "2030-01-01T00:00:10Z",
            "2030-01-01T00:00:20Z",
            "2030-01-01T00:00:30Z",
        ]
        for (index, timestamp) in timestamps.enumerated() {
            coordinator.piWorkStarted(scope: scope(), evidence: .init(
                sessionID: "s1",
                observedAt: timestamp,
                cursor: String(index + 1)
            ))
            coordinator.piWorkSettled(scope: scope(), evidence: .init(
                sessionID: "s1",
                observedAt: timestamp,
                cursor: String(index + 1)
            ))
        }
        #expect(recorder.count == 3)

        // The recovered fleet delivers all three fresh alerts at once without
        // any done transition: the pane was acknowledged and projects idle.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")], alerts: [
            alert("a1", createdAt: timestamps[0]),
            alert("a2", createdAt: timestamps[1]),
            alert("a3", createdAt: timestamps[2]),
        ])
        #expect(recorder.count == 3)

        // A fourth genuine turn is still eligible exactly once.
        coordinator.piWorkStarted(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:00:40Z",
            cursor: "4"
        ))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:00:40Z",
            cursor: "4"
        ))
        #expect(recorder.count == 4)
    }

    @Test("Delayed batched alerts use their own instant, not the pane's newer or stale cursor")
    func batchedAlertsWithIndependentPaneCursor() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])
        for turn in 1...3 {
            let time = "2030-01-01T00:00:\(turn * 10)Z"
            coordinator.piWorkStarted(scope: scope(), evidence: .init(
                sessionID: "s1", observedAt: time, cursor: String(turn * 10 - 1)
            ))
            coordinator.piWorkSettled(scope: scope(), evidence: .init(
                sessionID: "s1", observedAt: time, cursor: String(turn * 10)
            ))
        }
        #expect(recorder.count == 3)

        // The pane has already advanced past all three completions. Its
        // cursor cannot identify which completion each delayed alert reports.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0", piCursor: "40")], alerts: [
            alert("a1", createdAt: "2030-01-01T00:00:10Z"),
            alert("a2", createdAt: "2030-01-01T00:00:20Z"),
            alert("a3", createdAt: "2030-01-01T00:00:30Z"),
        ])
        #expect(recorder.count == 3)

        // Conversely, a new alert can arrive with a *stale* pane cursor.
        // Its later instant proves a new finish, not a replay of turn three.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0", piCursor: "30")], alerts: [
            alert("a4", createdAt: "2030-01-01T00:00:40Z")
        ])
        #expect(recorder.count == 4)
    }

    @Test("Batched alerts match every unordered Pi turn without truncation")
    func unorderedBatchedAlertsStaySilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])

        // Three turns settle with no ordering evidence and no fleet refresh.
        for _ in 0..<3 {
            coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
            coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        }
        #expect(recorder.count == 3)

        // A later refresh hands over all three alerts at once. Every already
        // heard completion owns one obligation, so none of them replays.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")], alerts: [
            alert("a1"),
            alert("a2"),
            alert("a3"),
        ])
        #expect(recorder.count == 3)

        // A fourth genuine turn is still eligible exactly once.
        coordinator.piWorkStarted(scope: scope(), evidence: .init(sessionID: "s1"))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(sessionID: "s1"))
        #expect(recorder.count == 4)
    }

    @Test("A covered snapshot start cannot clear a fleet receipt")
    func coveredSnapshotStartKeepsReceipt() {
        let (coordinator, recorder) = makeCoordinator()
        // The fleet observed the completion at cursor 11 before the committed
        // snapshot restored the still-active run at cursor 10.
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", piCursor: "11")])
        #expect(recorder.count == 1)

        coordinator.piWorkStarted(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:00:05Z",
            cursor: "10"
        ))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:00:30Z",
            cursor: "11"
        ))
        #expect(recorder.count == 1)

        // A genuinely later turn past the watermark still plays once.
        coordinator.piWorkStarted(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:01:00Z",
            cursor: "20"
        ))
        coordinator.piWorkSettled(scope: scope(), evidence: .init(
            sessionID: "s1",
            observedAt: "2030-01-01T00:01:05Z",
            cursor: "21"
        ))
        #expect(recorder.count == 2)
    }
}
