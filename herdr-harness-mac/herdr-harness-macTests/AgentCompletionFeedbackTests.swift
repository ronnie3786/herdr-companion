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
        machineID: String = "machine-a",
        paneID: String = "w1:p1",
        terminalID: String = "terminal-1"
    ) -> AgentCompletionFeedbackCoordinator.FleetObservation {
        AgentCompletionFeedbackCoordinator.FleetObservation(
            paneID: paneID,
            terminalID: terminalID,
            status: status,
            episodeKey: episodeKey,
            newDoneAlertID: newDoneAlertID
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

    @Test("Prompt start and a historical done result stay silent")
    func submissionAndHistoryAreSilent() {
        let (coordinator, recorder) = makeCoordinator()
        // Startup baseline: a previous completed answer is displayed.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e1")])

        // The user submits; committed work starts with the previous done still
        // displayed and the revision churning.
        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")

        #expect(recorder.count == 0)
    }

    @Test("One committed settlement plays once per episode")
    func settlementPlaysOncePerTurn() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e0")])

        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        #expect(recorder.count == 1)

        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        #expect(recorder.count == 2)
    }

    @Test("A settlement whose start was never published still plays once")
    func settlementWithoutPublishedStart() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        #expect(recorder.count == 1)
    }

    @Test("Fleet completion after a committed settlement never double-plays")
    func fleetAfterSettlementIsSilent() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
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
        coordinator.piWorkStarted(scope: scope(), sessionID: "s1")
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        #expect(recorder.count == 1)

        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
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

    @Test("A fresh alert whose pane is projected idle shares the same receipt")
    func freshAlertOwnsProjectedIdleCompletion() {
        let (coordinator, recorder) = makeCoordinator()
        refresh(coordinator, [paneObservation(.working, episodeKey: "e1")])
        // The user acknowledged quickly, so the companion projects the pane as
        // idle while the new completion alert still reports the transition.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e1")], alerts: [
            .init(paneID: pane, terminalID: terminal, alertID: "alert-1")
        ])
        #expect(recorder.count == 1)

        // The same alert observed again is not a second completion.
        refresh(coordinator, [paneObservation(.idle, episodeKey: "e1")], alerts: [
            .init(paneID: pane, terminalID: terminal, alertID: "alert-1")
        ])
        #expect(recorder.count == 1)
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
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        #expect(recorder.count == 1)

        // Every later replay of the same evidence is a duplicate.
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2", newDoneAlertID: "alert-1")])
        refresh(coordinator, [paneObservation(.done, episodeKey: "e2")])
        coordinator.piWorkSettled(scope: scope(), sessionID: "s1")
        #expect(recorder.count == 1)
    }
}
