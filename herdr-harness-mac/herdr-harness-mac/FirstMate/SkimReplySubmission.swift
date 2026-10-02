import Observation

@MainActor
@Observable
final class SkimReplySubmission {
    private(set) var sending = false
    private(set) var failed = false

    func send(_ action: SkimReplyAction, context: SkimReplyContext, state: SkimDisplayState) async {
        guard action.isValid, !sending, context.disabledReason == nil,
              !state.sentReplyIDs.contains(context.messageID) else { return }
        sending = true
        failed = false
        let accepted = await context.send(action.label)
        if accepted { state.didSendReply(for: context.messageID) }
        failed = !accepted
        sending = false
    }
}
