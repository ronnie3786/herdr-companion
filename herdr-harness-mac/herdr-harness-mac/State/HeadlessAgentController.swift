import Foundation
import Observation

@MainActor
@Observable
final class HeadlessAgentController {
    /// Whether this controller drives a user-facing run whose completion should
    /// play the companion cue. Internal summary and naming work keeps the
    /// default, so their terminal observations stay silent.
    let reportsCompletionFeedback: Bool
    private(set) var run: HeadlessAgentRun?
    private(set) var machineID: String?
    private(set) var isSubmitting = false
    private(set) var isPromoting = false
    private(set) var errorMessage: String?
    private(set) var lastErrorStatus: Int?

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    /// Deterministic test seams for the bounded run poll.
    @ObservationIgnored var pollingInterval: Duration = .milliseconds(700)
    @ObservationIgnored var pollingRetryInterval: Duration = .seconds(2)

    init(reportsCompletionFeedback: Bool = false) {
        self.reportsCompletionFeedback = reportsCompletionFeedback
    }

    deinit {
        pollingTask?.cancel()
    }

    var isRunning: Bool {
        isSubmitting || run?.status == .queued || run?.status == .running
    }

    var canPromote: Bool {
        run?.status == .completed && run?.sessionFile?.isEmpty == false && !isPromoting
    }

    func submit(
        prompt: String,
        machineID: String,
        mode: HeadlessAgentRunMode = .ask,
        cwd: String? = nil,
        agentModel: String? = nil,
        thinkingLevel: String? = nil,
        attachments: [HeadlessAgentAttachment]? = nil,
        continueFromRunId: String? = nil,
        systemPrompt: String? = nil,
        profile: String? = nil,
        model: HerdrAppModel
    ) async {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty, !isRunning else { return }

        stopPolling()
        self.machineID = machineID
        isSubmitting = true
        errorMessage = nil
        lastErrorStatus = nil
        do {
            let started = try await model.startHeadlessAgent(
                prompt: normalizedPrompt,
                machineID: machineID,
                cwd: cwd,
                mode: mode,
                model: agentModel,
                thinkingLevel: thinkingLevel,
                attachments: attachments,
                continueFromRunId: continueFromRunId,
                systemPrompt: systemPrompt,
                profile: profile
            )
            run = started
            isSubmitting = false
            if !started.status.isTerminal {
                beginPolling(runID: started.id, machineID: machineID, model: model)
            } else {
                // The run can finish before its first running poll. A locally
                // submitted run is current work even then; history observation
                // never takes this path.
                reportCompletionIfNeeded(started, machineID: machineID, model: model)
            }
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            if case let APIError.server(status, _) = error {
                lastErrorStatus = status
            }
        }
    }

    func cancel(model: HerdrAppModel) async {
        guard let run, let machineID, isRunning else { return }
        stopPolling()
        do {
            self.run = try await model.cancelHeadlessAgent(runID: run.id, machineID: machineID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            // A failed stop request must not strand this conversation in a
            // permanently running state with no observer.
            beginPolling(runID: run.id, machineID: machineID, model: model)
        }
    }

    func promote(
        workspaceID: String?,
        model: HerdrAppModel
    ) async -> HerdrPane? {
        guard let run, let machineID, canPromote else { return nil }
        isPromoting = true
        errorMessage = nil
        defer { isPromoting = false }
        do {
            let result = try await model.promoteHeadlessAgent(
                runID: run.id,
                machineID: machineID,
                workspaceID: workspaceID
            )
            self.run = result.run
            return result.pane
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func observe(_ run: HeadlessAgentRun, machineID: String, model: HerdrAppModel) {
        guard !isRunning else { return }
        stopPolling()
        self.run = run
        self.machineID = machineID
        if !run.status.isTerminal { beginPolling(runID: run.id, machineID: machineID, model: model) }
    }

    func reset() {
        guard !isRunning else { return }
        stopPolling()
        run = nil
        machineID = nil
        errorMessage = nil
        lastErrorStatus = nil
    }

    func discard(model: HerdrAppModel) async {
        guard let run, let machineID, !isRunning else { return }
        stopPolling()
        do {
            try await model.deleteHeadlessAgent(runID: run.id, machineID: machineID)
        } catch {
            errorMessage = error.localizedDescription
        }
        self.run = nil
        self.machineID = nil
    }

    func close(model: HerdrAppModel) async {
        guard !isSubmitting else { return }
        stopPolling()
        if let run, let machineID {
            if isRunning,
               let cancelled = try? await model.cancelHeadlessAgent(
                   runID: run.id,
                   machineID: machineID
               ) {
                self.run = cancelled
            }
            if self.run?.status.isTerminal == true {
                try? await model.deleteHeadlessAgent(runID: run.id, machineID: machineID)
            }
        }
        run = nil
        machineID = nil
        errorMessage = nil
    }

    private func beginPolling(runID: String, machineID: String, model: HerdrAppModel) {
        pollingTask = Task { [weak self] in
            var pollingDelay = self?.pollingInterval ?? .milliseconds(700)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollingDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                do {
                    let latest = try await model.fetchHeadlessAgent(runID: runID, machineID: machineID)
                    guard self.run?.id == runID else { return }
                    self.run = latest
                    self.errorMessage = nil
                    pollingDelay = self.pollingInterval
                    self.reportCompletionIfNeeded(latest, machineID: machineID, model: model)
                    if latest.status.isTerminal {
                        self.pollingTask = nil
                        return
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    pollingDelay = self.pollingRetryInterval
                }
            }
        }
    }

    /// A completed or promoted run the user asked for is the only headless
    /// work that plays the companion cue. The coordinator keeps the durable
    /// machine/run receipt, so repeated observations of the same run and a
    /// later continuation never play twice.
    private func reportCompletionIfNeeded(
        _ run: HeadlessAgentRun,
        machineID: String,
        model: HerdrAppModel
    ) {
        guard reportsCompletionFeedback,
              run.status == .completed || run.status == .promoted
        else { return }
        model.agentCompletionFeedback.headlessRunFinished(machineID: machineID, runID: run.id)
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
