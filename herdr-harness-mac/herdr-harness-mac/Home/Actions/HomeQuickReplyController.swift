import Foundation
import Observation

/// A root-owned bounded reader. Reading options never follows a conversation
/// stream, changes the main selection, or marks a response read.
@MainActor @Observable
final class HomeQuickReplyController {
    private(set) var presentations: [HomeRoute: HomeQuickReplyPresentation] = [:]
    @ObservationIgnored private let operations: HomeQuickReplyOperations
    @ObservationIgnored private var desired: [HomeRoute: Target] = [:]
    @ObservationIgnored private var jobs: [HomeRoute: Job] = [:]
    @ObservationIgnored private var lanes: [Task<Void, Never>?] = [nil, nil]
    @ObservationIgnored private var nextLane = 0
    @ObservationIgnored private var visibilityID = UUID()
    @ObservationIgnored private var answered: [HomeRoute: HomeQuickReplyQuestion] = [:]
    private var submissionDetails: [HomeRoute: SubmissionDetails] = [:]
    private var submissionOrder: [HomeRoute] = []
    private var acknowledgedOutcomes: [HomeRoute: HomeQuickReplyQuestion] = [:]

    private struct SubmissionDetails {
        var question: HomeQuickReplyQuestion
        var title: String
        var label: String
    }

    private struct Target: Equatable {
        var owner: HomeQuickReplyOwner
        var evidence: String
        var title: String
    }

    private struct Job {
        var id: UUID
        var target: Target
        var task: Task<Void, Never>
    }

    init(operations: HomeQuickReplyOperations) { self.operations = operations }

    convenience init(model: HerdrAppModel, shell: HerdrShellState) {
        let source = HomeQuickReplySource(model: model, shell: shell)
        self.init(operations: source.operations)
    }

    /// `chats` must be the cards actually inside the viewport, in visual order.
    /// A source evidence change replaces its work, while unchanged polling
    /// reuses the result. Two serial lanes cap even cancellation-ignoring reads.
    func hydrate(focus: HomeFocusItem?, chats: [HomeChatItem], enabled: Bool) async {
        let visibility = UUID()
        visibilityID = visibility
        var requested: [(HomeRoute, String, String)] = []
        if enabled {
            if let focus, !focus.isStale, !focus.isIdea,
               case .firstMate = focus.route {
                requested.append((focus.route, focus.fingerprint, focus.title))
            }
            for chat in chats.filter({ $0.isWaiting && !$0.isStale }).prefix(3) {
                requested.append((chat.route, chat.evidenceID, chat.title))
            }
        }
        var targets: [HomeRoute: Target] = [:]
        var order: [HomeRoute] = []
        for (route, evidence, title) in requested where targets[route] == nil {
            guard let owner = operations.owner(route) else { continue }
            targets[route] = Target(owner: owner, evidence: evidence, title: title)
            order.append(route)
        }
        let previous = desired
        desired = targets
        for (route, job) in jobs where targets[route] != job.target {
            job.task.cancel()
            jobs[route] = nil
        }
        for route in Array(presentations.keys) where targets[route] == nil {
            if presentations[route]?.phase.preservesSubmission != true { presentations[route] = nil }
        }
        for route in order {
            guard let target = targets[route] else { continue }
            if let presentation = presentations[route], presentation.phase.preservesSubmission {
                // A failed send never migrates to a replacement connection.
                if presentation.question?.owner != target.owner, presentation.phase != .accepted {
                    if presentation.phase != .sending {
                        presentations[route]?.phase = .deliveryUnconfirmed(
                            "This conversation's connection changed. Open it to check the previous reply.", retryable: false)
                    }
                    continue
                } else if presentation.phase != .accepted || previous[route] == target {
                    continue
                }
            }
            if jobs[route]?.target == target { continue }
            if previous[route] == target, let phase = presentations[route]?.phase, phase != .loading { continue }
            presentations[route] = .init(question: nil, phase: .loading)
            schedule(target)
        }
        operations.retain(Array(targets.values.map(\.owner)))
        let waiting = order.compactMap { jobs[$0]?.task }
        await withTaskCancellationHandler {
            for task in waiting { await task.value }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelHydration(visibility: visibility) }
        }
    }

    func send(_ action: SkimReplyAction, to route: HomeRoute, question: HomeQuickReplyQuestion) async {
        guard let target = desired[route], target.owner == question.owner,
              presentations[route]?.phase == .ready,
              presentations[route]?.question == question,
              question.actions.contains(action), action.isValid,
              operations.owner(route) == question.owner else { return }
        presentations[route]?.phase = .sending
        jobs[route]?.task.cancel()
        jobs[route] = nil
        do {
            let latest = try await operations.load(question.owner)
            guard desired[route] == target, operations.owner(route) == question.owner,
                  latest.question == question, latest.unavailableReason == nil else {
                presentations[route]?.phase = .unavailable("The question or conversation changed. Open it to review the latest response.")
                return
            }
        } catch {
            presentations[route]?.phase = .unavailable("Could not verify the latest question. Open the conversation before replying.")
            return
        }
        // No suspension between the final owner check and the existing owner
        // reserving its submission. The displayed label is the entire payload.
        // Publish the persistent status only at this boundary. Resizing Home
        // during question verification must not remove the card from view.
        submissionDetails[route] = .init(question: question, title: target.title, label: action.label)
        if !submissionOrder.contains(route) { submissionOrder.append(route) }
        let result = await operations.submit(question, action)
        if result == .accepted { answered[route] = question }
        record(result, question: question, route: route)
    }

    func retry(route: HomeRoute) async {
        guard let presentation = presentations[route], presentation.phase.canRetry,
              let question = presentation.question,
              operations.owner(route) == question.owner else { return }
        presentations[route]?.phase = .sending
        let result = await operations.retry(question.owner)
        if result == .accepted { answered[route] = question }
        record(result, question: question, route: route)
    }

    func canRetry(route: HomeRoute) -> Bool {
        guard let presentation = presentations[route], presentation.phase.canRetry,
              let question = presentation.question else { return false }
        return operations.owner(route) == question.owner
    }

    var unresolvedOutcomes: [HomeQuickReplyOutcome] {
        submissionOrder.compactMap { route in
            guard let presentation = presentations[route], presentation.phase.needsResolution,
                  let details = submissionDetails[route], presentation.question == details.question,
                  acknowledgedOutcomes[route] != details.question else { return nil }
            return .init(question: details.question, title: details.title, replyLabel: details.label, phase: presentation.phase)
        }
    }

    func canOpenOutcome(_ outcome: HomeQuickReplyOutcome) -> Bool {
        isDestinationCurrent(outcome.owner)
    }

    func canAcknowledge(_ outcome: HomeQuickReplyOutcome) -> Bool {
        outcome.phase.canAcknowledge && unresolvedOutcomes.contains(outcome)
    }

    /// This only hides an inspected receipt. Delivery remains uncertain and
    /// the original question stays reserved against another quick submission.
    func acknowledge(_ outcome: HomeQuickReplyOutcome) {
        guard canAcknowledge(outcome) else { return }
        acknowledgedOutcomes[outcome.id] = outcome.question
    }

    /// A synchronous pause makes disappearance safe even after a hydration
    /// task has already completed. In-flight submissions keep their owner.
    func pauseHydration() { cancelHydration(visibility: visibilityID) }

    private func record(_ result: HomeQuickReplyResult, question: HomeQuickReplyQuestion, route: HomeRoute) {
        let phase: HomeQuickReplyPresentation.Phase
        if result != .accepted, !isDestinationCurrent(question.owner) {
            phase = .deliveryUnconfirmed("This conversation's connection changed. Open it to check the previous reply.", retryable: false)
        } else {
            phase = result.phase
        }
        presentations[route] = .init(question: question, phase: phase)
    }

    private func isDestinationCurrent(_ owner: HomeQuickReplyOwner) -> Bool {
        operations.isDestinationCurrent?(owner) ?? (operations.owner(owner.route) == owner)
    }

    private func schedule(_ target: Target) {
        let route = target.owner.route
        let jobID = UUID()
        let lane = nextLane
        nextLane = (nextLane + 1) % lanes.count
        let predecessor = lanes[lane]
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self, !Task.isCancelled, self.desired[route] == target,
                  self.operations.owner(route) == target.owner else { return }
            do {
                let result = try await self.operations.load(target.owner)
                guard !Task.isCancelled, self.jobs[route]?.id == jobID,
                      self.desired[route] == target, self.operations.owner(route) == target.owner else { return }
                if let question = result.question, question.owner == target.owner,
                   !question.actions.isEmpty, result.unavailableReason == nil {
                    self.presentations[route] = .init(question: question,
                                                      phase: self.answered[route] == question ? .accepted : .ready)
                } else {
                    self.presentations[route] = .init(question: nil, phase: .unavailable(
                        result.unavailableReason ?? "Open the conversation to reply."))
                }
            } catch {
                guard !Task.isCancelled, self.jobs[route]?.id == jobID,
                      self.desired[route] == target, self.operations.owner(route) == target.owner else { return }
                self.presentations[route] = .init(question: nil, phase: .unavailable("Reply options are unavailable. Open the conversation to reply."))
            }
            if self.jobs[route]?.id == jobID { self.jobs[route] = nil }
        }
        jobs[route] = Job(id: jobID, target: target, task: task)
        lanes[lane] = task
    }

    private func cancelHydration(visibility: UUID) {
        guard visibilityID == visibility else { return }
        for job in jobs.values { job.task.cancel() }
        jobs = [:]
        desired = [:]
        presentations = presentations.filter { $0.value.phase.preservesSubmission }
        operations.retain([])
    }
}
