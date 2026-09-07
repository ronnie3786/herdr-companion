import Foundation
import Observation
import os

private let cleanupLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "herdr-harness-mac",
    category: "cleanup"
)

@MainActor
@Observable
final class CleanupRunController {
    typealias ApplyProgressHandler = @Sendable (CleanupRunEnvelope) async -> Void
    typealias ApplyOperation = (
        String,
        [String],
        [String],
        ApplyProgressHandler
    ) async throws -> CleanupApplyResponse

    enum State: Equatable {
        case idle
        case running(CleanupRunEnvelope)
        case report(CleanupRunEnvelope)
        case failure(String)
        case applying(CleanupRunEnvelope?)
        case applyStatusUnknown(String)
        case applied(CleanupApplyResponse, CleanupRunEnvelope)
    }

    var state: State = .idle
    private(set) var activeRunID: String?
    private(set) var lastEnvelope: CleanupRunEnvelope?
    private(set) var consecutivePollFailures = 0
    private(set) var lastPollFailureMessage: String?
    private(set) var lastPollSucceededAt: Date?
    private(set) var latestApplyEnvelope: CleanupRunEnvelope?
    static let maxConsecutivePollFailures = 8

    private let isDemoMode: Bool
    private let pollInterval: Duration
    private let demoPhaseInterval: Duration
    private let startRequest: (CleanupStartRunRequest) async throws -> CleanupStartRunResponse
    private let fetchRun: (String) async throws -> CleanupRunEnvelope
    private let applyRun: ApplyOperation
    private let cancel: (String) async throws -> Void
    private let runContext: String
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var pollingGeneration = 0
    @ObservationIgnored private var pendingApply: PendingApply?

    private struct PendingApply {
        let report: CleanupRunEnvelope
        let paneIDs: [String]
        let workspaceIDs: [String]
    }

    convenience init(
        isDemoMode: Bool,
        pollInterval: Duration = .seconds(1),
        demoPhaseInterval: Duration = .seconds(1),
        runContext: String = "",
        start: @escaping (CleanupStartRunRequest) async throws -> CleanupStartRunResponse,
        fetch: @escaping (String) async throws -> CleanupRunEnvelope,
        apply: @escaping (String, [String], [String]) async throws -> CleanupApplyResponse,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.init(
            isDemoMode: isDemoMode,
            pollInterval: pollInterval,
            demoPhaseInterval: demoPhaseInterval,
            runContext: runContext,
            start: start,
            fetch: fetch,
            applyWithProgress: { runID, paneIDs, workspaceIDs, _ in
                try await apply(runID, paneIDs, workspaceIDs)
            },
            cancel: cancel
        )
    }

    init(
        isDemoMode: Bool,
        pollInterval: Duration = .seconds(1),
        demoPhaseInterval: Duration = .seconds(1),
        runContext: String = "",
        start: @escaping (CleanupStartRunRequest) async throws -> CleanupStartRunResponse,
        fetch: @escaping (String) async throws -> CleanupRunEnvelope,
        applyWithProgress: @escaping ApplyOperation,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.isDemoMode = isDemoMode
        self.pollInterval = pollInterval
        self.demoPhaseInterval = demoPhaseInterval
        startRequest = start
        fetchRun = fetch
        applyRun = applyWithProgress
        self.cancel = cancel
        self.runContext = runContext
    }

    deinit { pollingTask?.cancel() }

    func start() async {
        stopPolling()
        activeRunID = nil
        lastEnvelope = nil
        latestApplyEnvelope = nil
        pendingApply = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        if isDemoMode {
            let envelope = Self.demoRunningSnapshot(phase: .collecting)
            activeRunID = envelope.run.runID
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: envelope.run.runID)
            pollingTask = Task { [weak self] in
                await self?.advanceDemo()
            }
            return
        }

        let settings = CleanupSettings.load(from: .standard)
        do {
            let response = try await startRequest(
                CleanupStartRunRequest(
                    model: settings.model.isEmpty ? nil : settings.model,
                    thinkingLevel: settings.thinkingLevel,
                    costThresholdUSD: settings.costThresholdUSD,
                    tailLines: nil,
                    keepEvidence: nil,
                    workspaceIDs: nil
                )
            )
            let envelope = Self.initialEnvelope(for: response, settings: settings)
            activeRunID = response.runID
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: response.runID)
            cleanupLog.info("run started id=\(response.runID, privacy: .public) \(self.runContext, privacy: .public)")
            beginPolling(runID: response.runID)
        } catch {
            transition(to: .failure(error.localizedDescription))
        }
    }

    func retry() async {
        guard let runID = activeRunID else {
            cleanupLog.info("retry requested without an active run")
            await start()
            return
        }

        cleanupLog.info("retry requested run=\(runID, privacy: .public)")
        stopPolling()
        resetPollFailureState()
        if let lastEnvelope {
            transition(to: .running(lastEnvelope), runID: runID)
        }
        await poll(runID: runID)
        guard case .running = state, activeRunID == runID else { return }
        beginPolling(runID: runID)
    }

    func startOver() async {
        cleanupLog.info("start over requested run=\(self.activeRunID ?? "none", privacy: .public)")
        if let runID = activeRunID {
            stopPolling()
            do {
                try await cancel(runID)
            } catch {
                // Cancellation is best-effort. Starting a new run is still the user's explicit intent.
            }
        }
        activeRunID = nil
        lastEnvelope = nil
        latestApplyEnvelope = nil
        pendingApply = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        transition(to: .idle)
        await start()
    }

    func apply(paneIDs: [String], workspaceIDs: [String]) async {
        guard case let .report(envelope) = state else { return }
        let runID = envelope.run.runID
        cleanupLog.info("apply requested run=\(runID, privacy: .public)")
        activeRunID = runID
        latestApplyEnvelope = nil
        let pending = PendingApply(report: envelope, paneIDs: paneIDs, workspaceIDs: workspaceIDs)
        pendingApply = pending
        await performApply(pending)
    }

    func retryApplyStatus() async {
        guard case .applyStatusUnknown = state, let pendingApply else { return }
        cleanupLog.info("apply status retry requested run=\(pendingApply.report.run.runID, privacy: .public)")
        await performApply(pendingApply)
    }

    private func performApply(_ pending: PendingApply) async {
        let runID = pending.report.run.runID
        transition(to: .applying(latestApplyEnvelope), runID: runID)
        do {
            let response = try await applyRun(
                runID,
                pending.paneIDs,
                pending.workspaceIDs
            ) { [weak self] envelope in
                await self?.receiveApplyProgress(envelope, runID: runID)
            }
            guard pendingApply?.report.run.runID == runID else { return }
            if case .applied = state { return }
            transition(to: .applied(response, pending.report), runID: runID)
            pendingApply = nil
        } catch is CancellationError {
            return
        } catch let APIError.cleanupApplyStatusUnknown(message) {
            guard pendingApply?.report.run.runID == runID else { return }
            if case .applied = state { return }
            transition(to: .applyStatusUnknown(message), runID: runID)
        } catch {
            guard pendingApply?.report.run.runID == runID else { return }
            pendingApply = nil
            transition(to: .failure(error.localizedDescription), runID: runID)
        }
    }

    private func receiveApplyProgress(_ envelope: CleanupRunEnvelope, runID: String) {
        guard pendingApply?.report.run.runID == runID else { return }
        guard envelope.run.status == .applying
                || envelope.run.status == .applied
                || envelope.run.status == .failed
                || envelope.applyResult != nil
        else { return }
        latestApplyEnvelope = envelope
        lastPollSucceededAt = .now
        if envelope.run.status == .applied || envelope.run.status == .failed,
           let response = envelope.applyResult,
           let pendingApply {
            transition(to: .applied(response, pendingApply.report), runID: runID)
            self.pendingApply = nil
        } else {
            transition(to: .applying(envelope), runID: runID)
        }
    }

    func cancelRun() async {
        guard let runID = activeRunID else { return }
        cleanupLog.info("cancel requested run=\(runID, privacy: .public)")
        stopPolling()
        do {
            try await cancel(runID)
        } catch {
            // Cancellation is best-effort. The next user action can safely retry.
        }
        activeRunID = nil
        lastEnvelope = nil
        latestApplyEnvelope = nil
        pendingApply = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        transition(to: .idle, runID: runID)
    }

    func stopPolling() {
        pollingGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    func resumeIfNeeded() {
        guard case .running = state, let runID = activeRunID, pollingTask == nil else { return }
        cleanupLog.info("reattaching polling run=\(runID, privacy: .public)")
        beginPolling(runID: runID)
    }

    private func beginPolling(runID: String) {
        let pollInterval = self.pollInterval
        pollingGeneration += 1
        let generation = pollingGeneration
        pollingTask = Task { [weak self, pollInterval, generation] in
            var exitReason = "finished"
            defer {
                self?.clearPollingTask(generation: generation)
                cleanupLog.info("polling exited run=\(runID, privacy: .public): \(exitReason, privacy: .public)")
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    exitReason = Task.isCancelled ? "cancelled" : "sleep interrupted"
                    return
                }
                guard !Task.isCancelled else {
                    exitReason = "cancelled"
                    return
                }
                guard let self else {
                    exitReason = "controller released"
                    return
                }
                guard self.activeRunID == runID else {
                    exitReason = "active run changed"
                    return
                }
                await self.poll(runID: runID)
                guard case .running = self.state, self.activeRunID == runID else {
                    exitReason = self.consecutivePollFailures >= Self.maxConsecutivePollFailures
                        ? "failure cap reached"
                        : "state left running"
                    return
                }
            }
            exitReason = "cancelled"
        }
    }

    private func poll(runID: String) async {
        guard activeRunID == runID else { return }
        do {
            let envelope = try await fetchRun(runID)
            guard activeRunID == runID else { return }
            resetPollFailureState()
            lastPollSucceededAt = .now
            lastEnvelope = envelope
            if envelope.run.status == .applied || envelope.run.status == .failed,
               let response = envelope.applyResult {
                let report = pendingApply?.report ?? envelope
                transition(to: .applied(response, report), runID: runID)
                pendingApply = nil
            } else if envelope.run.status.isTerminal {
                if envelope.workspaces != nil {
                    transition(to: .report(envelope), runID: runID)
                } else {
                    transition(to: .failure(Self.failureMessage(for: envelope.run)), runID: runID)
                }
            } else {
                transition(to: .running(envelope), runID: runID)
            }
        } catch {
            guard activeRunID == runID else { return }
            consecutivePollFailures += 1
            lastPollFailureMessage = error.localizedDescription
            cleanupLog.error("poll failed run=\(runID, privacy: .public) count=\(self.consecutivePollFailures): \(error.localizedDescription, privacy: .public)")
            if consecutivePollFailures >= Self.maxConsecutivePollFailures {
                transition(
                    to: .failure(
                        "\(error.localizedDescription) (run \(runID), after \(Self.maxConsecutivePollFailures) failed polls)"
                    ),
                    runID: runID
                )
            }
        }
    }

    private func advanceDemo() async {
        for phase in [CleanupPhase.judging, .gating] {
            do {
                try await Task.sleep(for: demoPhaseInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let envelope = Self.demoRunningSnapshot(phase: phase)
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: envelope.run.runID)
        }
        do {
            try await Task.sleep(for: demoPhaseInterval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let envelope = Self.demoReport()
        lastEnvelope = envelope
        transition(to: .report(envelope), runID: envelope.run.runID)
    }

    private func resetPollFailureState() {
        consecutivePollFailures = 0
        lastPollFailureMessage = nil
    }

    private func clearPollingTask(generation: Int) {
        guard pollingGeneration == generation else { return }
        pollingTask = nil
    }

    private func transition(to newState: State, runID: String? = nil) {
        let oldLabel = Self.stateLabel(state)
        state = newState
        cleanupLog.info(
            "state \(oldLabel, privacy: .public) -> \(Self.stateLabel(newState), privacy: .public) run=\(runID ?? self.activeRunID ?? "none", privacy: .public)"
        )
    }

    private static func stateLabel(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .report: "report"
        case let .failure(message): "failure: \(message)"
        case .applying: "applying"
        case .applyStatusUnknown: "apply status unknown"
        case .applied: "applied"
        }
    }

    private static func initialEnvelope(
        for response: CleanupStartRunResponse,
        settings: CleanupSettings
    ) -> CleanupRunEnvelope {
        CleanupRunEnvelope(
            ok: response.ok,
            run: CleanupRun(
                runID: response.runID,
                status: response.status,
                phase: .collecting,
                phaseDetail: "Capturing workspace and pane metadata",
                progress: CleanupProgress(done: 0, total: 1),
                config: CleanupRunConfig(
                    model: settings.model.isEmpty ? nil : settings.model,
                    thinkingLevel: settings.thinkingLevel,
                    costThresholdUSD: settings.costThresholdUSD,
                    tailLines: nil,
                    minConfidence: nil
                )
            ),
            workspaces: nil,
            summary: nil
        )
    }

    private static func failureMessage(for run: CleanupRun) -> String {
        var message = run.error ?? "Cleanup failed"
        if let lastError = run.judge?.lastError, !lastError.isEmpty, lastError != message {
            message += "\n\nJudge error: \(lastError)"
        }
        return message
    }

    static func demoRunningSnapshot(phase: CleanupPhase) -> CleanupRunEnvelope {
        let status: CleanupRunStatus
        let detail: String
        let progress: CleanupProgress
        let history: [CleanupPhaseHistoryEntry]
        let runStartedAt: String
        let now = Date()
        let formatter = ISO8601DateFormatter()
        func timestamp(secondsAgo: TimeInterval) -> String {
            formatter.string(from: now.addingTimeInterval(-secondsAgo))
        }
        switch phase {
        case .collecting:
            status = .collecting
            detail = "Capturing pane 4 of 5"
            progress = CleanupProgress(done: 4, total: 5)
            runStartedAt = timestamp(secondsAgo: 4)
            history = [CleanupPhaseHistoryEntry(phase: .collecting, startedAt: runStartedAt, finishedAt: nil, detail: nil)]
        case .judging:
            status = .judging
            detail = "Judging workspace \"garden-catalog\" (batch 1 of 2)"
            progress = CleanupProgress(done: 1, total: 2)
            runStartedAt = timestamp(secondsAgo: 20)
            history = [
                CleanupPhaseHistoryEntry(phase: .collecting, startedAt: runStartedAt, finishedAt: timestamp(secondsAgo: 16), detail: "Captured 5 panes across 2 workspaces"),
                CleanupPhaseHistoryEntry(phase: .judging, startedAt: timestamp(secondsAgo: 16), finishedAt: nil, detail: nil),
            ]
        case .gating:
            status = .gating
            detail = "Checking pane activity, Pi sessions, and safety rails"
            progress = CleanupProgress(done: 4, total: 5)
            runStartedAt = timestamp(secondsAgo: 50)
            history = [
                CleanupPhaseHistoryEntry(phase: .collecting, startedAt: runStartedAt, finishedAt: timestamp(secondsAgo: 46), detail: "Captured 5 panes across 2 workspaces"),
                CleanupPhaseHistoryEntry(phase: .judging, startedAt: timestamp(secondsAgo: 46), finishedAt: timestamp(secondsAgo: 19), detail: "Judged 2 batches across 2 workspaces: Garden Catalog, Weather Samples"),
                CleanupPhaseHistoryEntry(phase: .gating, startedAt: timestamp(secondsAgo: 19), finishedAt: nil, detail: nil),
            ]
        case .applying:
            status = .applying
            detail = "Ending active Pi sessions before closing approved panes"
            progress = CleanupProgress(done: 1, total: 3)
            runStartedAt = timestamp(secondsAgo: 65)
            history = [
                CleanupPhaseHistoryEntry(phase: .collecting, startedAt: runStartedAt, finishedAt: timestamp(secondsAgo: 61), detail: "Captured 5 panes across 2 workspaces"),
                CleanupPhaseHistoryEntry(phase: .judging, startedAt: timestamp(secondsAgo: 61), finishedAt: timestamp(secondsAgo: 34), detail: "Judged 2 batches across 2 workspaces: Garden Catalog, Weather Samples"),
                CleanupPhaseHistoryEntry(phase: .gating, startedAt: timestamp(secondsAgo: 34), finishedAt: timestamp(secondsAgo: 15), detail: "Checked activity, Pi sessions, and deterministic safety rails"),
                CleanupPhaseHistoryEntry(phase: .applying, startedAt: timestamp(secondsAgo: 15), finishedAt: nil, detail: nil),
            ]
        case .done, .failed:
            return demoReport()
        }
        return CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_demo",
                status: status,
                phase: phase,
                phaseDetail: detail,
                progress: progress,
                phaseHistory: history,
                startedAt: runStartedAt,
                session: "default",
                config: demoConfig
            ),
            workspaces: nil,
            summary: nil
        )
    }

    static func demoReport() -> CleanupRunEnvelope {
        let finishedAt = "2030-01-01T20:06:02Z"
        return CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_demo",
                status: .done,
                phase: .done,
                phaseDetail: "Cleanup report ready for your review",
                progress: CleanupProgress(done: 2, total: 2),
                phaseHistory: [
                    CleanupPhaseHistoryEntry(phase: .collecting, startedAt: "2030-01-01T20:04:11Z", finishedAt: "2030-01-01T20:04:15Z", detail: "Captured 5 panes across 2 workspaces"),
                    CleanupPhaseHistoryEntry(phase: .judging, startedAt: "2030-01-01T20:04:15Z", finishedAt: "2030-01-01T20:05:38Z", detail: "Judged 2 batches across 2 workspaces: Garden Catalog, Weather Samples"),
                    CleanupPhaseHistoryEntry(phase: .gating, startedAt: "2030-01-01T20:05:38Z", finishedAt: finishedAt, detail: "Checked activity, Pi sessions, and deterministic safety rails"),
                ],
                startedAt: "2030-01-01T20:04:11Z",
                finishedAt: finishedAt,
                session: "default",
                config: demoConfig,
                judge: CleanupJudgeSummary(batches: 2, failedBatches: 0, costUSD: 0.031, durationMs: 83_210, lastError: nil)
            ),
            workspaces: [demoWorkspaceOne, demoWorkspaceTwo],
            summary: CleanupSummary(
                panesScanned: 5,
                closeCandidates: 3,
                railBlocked: 2,
                costFlags: [
                    CleanupCostFlag(paneID: "w3:p1", costUSD: 3.41),
                    CleanupCostFlag(paneID: "w9:p1", costUSD: 2.46),
                ],
                totalKnownCostUSD: 5.87,
                unknownCostPanes: 3,
                workspacesScanned: 2,
                workspaceCloseCandidates: 0,
                workspaceTitles: ["Garden Catalog", "Weather Samples"],
                workspaceSummaries: [
                    CleanupWorkspaceSummary(
                        workspaceID: "w3",
                        title: "Garden Catalog",
                        summary: "The fictional seed catalog is complete. Two panes are finished or stale, while the test runner is still producing output.",
                        workspaceReason: "Keep the workspace until the active test run reaches a stable result.",
                        paneCount: 3,
                        closeCandidates: 2,
                        railBlocked: 1,
                        activePanes: 1,
                        piPanes: 1,
                        activePiSessions: 1
                    ),
                    CleanupWorkspaceSummary(
                        workspaceID: "w9",
                        title: "Weather Samples",
                        summary: "The fictional weather display is complete, but its sample data commits remain unpushed and focused.",
                        workspaceReason: "Keep this workspace so the fictional weather values can be reviewed.",
                        paneCount: 2,
                        closeCandidates: 1,
                        railBlocked: 1,
                        activePanes: 0,
                        piPanes: 1,
                        activePiSessions: 1
                    ),
                ],
                classifications: [
                    "completed": 1,
                    "stale": 2,
                    "active": 1,
                    "blocked": 0,
                    "needs_human": 1,
                    "unknown": 0,
                ],
                activePanes: 1,
                blockedPanes: 1,
                piPanes: 2,
                activePiSessions: 2,
                knownCostPanes: 2
            )
        )
    }

    private static let demoConfig = CleanupRunConfig(
        model: "local-model/example-model",
        thinkingLevel: .medium,
        costThresholdUSD: 2.0,
        tailLines: 400,
        minConfidence: 0.6
    )

    private static let demoWorkspaceOne = CleanupWorkspaceReport(
        workspaceID: "w3",
        label: "garden-catalog",
        workspaceCloseRecommended: false,
        workspaceSafeToClose: false,
        workspaceBlockedBy: ["R6:pane_blocked"],
        git: CleanupGitStatus(state: .clean),
        panes: [
            CleanupPaneReport(
                paneID: "w3:p1",
                title: "pi · garden-catalog",
                agentKind: "pi",
                agentStatus: .done,
                classification: .completed,
                confidence: 0.92,
                reason: "The final assistant turn says sample PR #1 was merged, and the done alert is six hours old.",
                closeRecommended: true,
                safeToClose: true,
                blockedBy: [],
                costUSD: 3.41,
                costSource: "sessionFile",
                costOverThreshold: true,
                signals: CleanupSignals(
                    doneAlertAgeSeconds: 21_600,
                    revisionChanged: false,
                    sessionFileAgeSeconds: 22_110,
                    starred: false,
                    focused: false,
                    unreadAlerts: 0,
                    agentStatus: .done,
                    blockedAlertAgeSeconds: nil,
                    piStateAgeSeconds: 21_580,
                    piConnected: true,
                    piActive: true,
                    piWorking: false,
                    endsAtShellPrompt: false,
                    hasProcessExitedMarker: false,
                    looksLikeIdleAgentTUI: true,
                    tailIsEmpty: false,
                    tailTruncated: false
                ),
                summary: "Completed three fictional seed entries and saved the sample catalog. No unfinished demo work is visible.",
                activitySummary: "The pane stayed unchanged during the sample. Pi is connected but idle, and its latest done alert is six hours old.",
                usageSummary: "Pi session demo-garden-001 is connected; $3.41 and 186,420 tokens used.",
                evidenceCited: [
                    "transcript.md: sample PR #1 contains three fictional seed entries",
                    "signal:agentStatus=done",
                    "signal:revisionChanged=false",
                ],
                piSession: CleanupPiSession(
                    detected: true,
                    sessionID: "pi_demo_garden_001",
                    sessionFile: "~/.pi/agent/sessions/garden-catalog/pi_demo_garden_001.jsonl",
                    sessionName: "demo-garden-001",
                    cwd: "/tmp/herdr-demo/garden-catalog",
                    connected: true,
                    active: true,
                    idle: true,
                    costUSD: 3.41,
                    totalTokens: 186_420
                )
            ),
            CleanupPaneReport(
                paneID: "w3:p2",
                title: "tests · garden-catalog",
                agentKind: "shell",
                agentStatus: .working,
                classification: .active,
                confidence: 0.88,
                reason: "The integration test runner printed three new test results during the activity sample.",
                closeRecommended: false,
                safeToClose: false,
                blockedBy: ["R1:working", "R4:active_output"],
                costUSD: nil,
                costSource: nil,
                costOverThreshold: false,
                signals: CleanupSignals(
                    doneAlertAgeSeconds: nil,
                    revisionChanged: true,
                    sessionFileAgeSeconds: nil,
                    starred: false,
                    focused: false,
                    unreadAlerts: 0,
                    agentStatus: .working,
                    piConnected: false,
                    piActive: false,
                    piWorking: false,
                    endsAtShellPrompt: false,
                    hasProcessExitedMarker: false,
                    looksLikeIdleAgentTUI: false,
                    tailIsEmpty: false,
                    tailTruncated: false
                ),
                summary: "Validating fictional seed entries. The sample run is still active, with 118 of 164 checks complete.",
                activitySummary: "Terminal output changed during the sample and the process has not returned to a shell prompt.",
                usageSummary: "No Pi session was detected.",
                evidenceCited: [
                    "tail.txt: [118/164] DemoSeedCatalogChecks",
                    "signal:revisionChanged=true",
                ]
            ),
            CleanupPaneReport(
                paneID: "w3:p3",
                title: "notes · garden-catalog",
                agentKind: "shell",
                agentStatus: .idle,
                classification: .stale,
                confidence: 0.78,
                reason: "The pane contains copied investigation notes, has no alerts, and ends at an idle shell prompt.",
                closeRecommended: true,
                safeToClose: true,
                blockedBy: [],
                costUSD: nil,
                costSource: nil,
                costOverThreshold: false,
                signals: CleanupSignals(
                    doneAlertAgeSeconds: nil,
                    revisionChanged: false,
                    sessionFileAgeSeconds: nil,
                    starred: false,
                    focused: false,
                    unreadAlerts: 0,
                    agentStatus: .idle,
                    piConnected: false,
                    piActive: false,
                    piWorking: false,
                    endsAtShellPrompt: true,
                    hasProcessExitedMarker: true,
                    looksLikeIdleAgentTUI: false,
                    tailIsEmpty: false,
                    tailTruncated: false
                ),
                summary: "Scratch pane containing fictional seed colors. The useful entries are already in the sample catalog.",
                activitySummary: "No output changed during the sample, and the pane ends at a shell prompt.",
                usageSummary: "No Pi session was detected.",
                evidenceCited: ["tail.txt: investigation notes followed by a shell prompt"]
            ),
        ],
        title: "Garden Catalog",
        workspaceReason: "Keep the workspace until the active integration suite finishes.",
        summary: "The sample seed catalog is complete. Two panes are safe to close, while one test pane is still active."
    )

    private static let demoWorkspaceTwo = CleanupWorkspaceReport(
        workspaceID: "w9",
        label: "weather-samples",
        workspaceCloseRecommended: false,
        workspaceSafeToClose: false,
        workspaceBlockedBy: ["R2:focused_workspace", "R6:git_unpushed"],
        git: CleanupGitStatus(state: .unpushed),
        panes: [
            CleanupPaneReport(
                paneID: "w9:p1",
                title: "pi · weather-samples",
                agentKind: "pi",
                agentStatus: .done,
                classification: .needsHuman,
                confidence: 0.63,
                reason: "The fictional weather checklist is complete, but two commits containing sample temperatures have not been pushed.",
                closeRecommended: false,
                safeToClose: false,
                blockedBy: ["R2:focused_workspace", "R6:git_unpushed"],
                costUSD: 2.46,
                costSource: "bridge",
                costOverThreshold: true,
                signals: CleanupSignals(
                    doneAlertAgeSeconds: 3_600,
                    revisionChanged: false,
                    sessionFileAgeSeconds: 3_900,
                    starred: false,
                    focused: true,
                    unreadAlerts: 0,
                    agentStatus: .done,
                    piStateAgeSeconds: 3_580,
                    piConnected: true,
                    piActive: true,
                    piWorking: false,
                    endsAtShellPrompt: false,
                    hasProcessExitedMarker: false,
                    looksLikeIdleAgentTUI: true,
                    tailIsEmpty: false,
                    tailTruncated: false
                ),
                summary: "Completed a fictional weather display and drafted example temperatures. Two sample commits still need review and push.",
                activitySummary: "Pi is connected and idle. The pane is focused, with no output changes during the sample.",
                usageSummary: "Pi session weather-samples is connected; $2.46 and 121,870 tokens used.",
                evidenceCited: [
                    "transcript.md: fictional weather readings saved in local sample commits",
                    "signal:gitState=unpushed",
                ],
                piSession: CleanupPiSession(
                    detected: true,
                    sessionID: "pi_demo_weather_002",
                    sessionFile: "~/.pi/agent/sessions/weather-samples/pi_demo_weather_002.jsonl",
                    sessionName: "weather-samples",
                    cwd: "/tmp/herdr-demo/weather-samples",
                    connected: true,
                    active: true,
                    idle: true,
                    costUSD: 2.46,
                    totalTokens: 121_870
                )
            ),
            CleanupPaneReport(
                paneID: "w9:p2",
                title: "sample rendering log",
                agentKind: "shell",
                agentStatus: .idle,
                classification: .stale,
                confidence: 0.81,
                reason: "The fictional weather rendering completed, and the sample log remains unchanged at a shell prompt.",
                closeRecommended: true,
                safeToClose: true,
                blockedBy: [],
                costUSD: nil,
                costSource: nil,
                costOverThreshold: false,
                signals: CleanupSignals(
                    doneAlertAgeSeconds: nil,
                    revisionChanged: false,
                    sessionFileAgeSeconds: nil,
                    starred: false,
                    focused: false,
                    unreadAlerts: 0,
                    agentStatus: .idle,
                    piConnected: false,
                    piActive: false,
                    piWorking: false,
                    endsAtShellPrompt: true,
                    hasProcessExitedMarker: true,
                    looksLikeIdleAgentTUI: false,
                    tailIsEmpty: false,
                    tailTruncated: false
                ),
                summary: "Rendered twelve fictional temperature samples. The example validation checks all passed.",
                activitySummary: "No output changed during the sample, and the sample rendering command exited successfully.",
                usageSummary: "No Pi session was detected.",
                evidenceCited: ["tail.txt: sample render complete, 12/12 example checks passing"]
            ),
        ],
        title: "Weather Samples",
        workspaceReason: "Keep the workspace because fictional weather data is still unpushed.",
        summary: "The example weather display passed its checks, but sample data commits still need review."
    )
}
