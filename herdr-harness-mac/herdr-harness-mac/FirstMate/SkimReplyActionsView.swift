import SwiftUI

struct SkimReplyActionsView: View {
    let actions: [SkimReplyAction]
    let context: SkimReplyContext
    let state: SkimDisplayState
    @Environment(\.chatProsePalette) private var palette
    @State private var submission = SkimReplySubmission()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkimReplyFlowLayout(spacing: 8) {
                ForEach(actions) { action in
                    Button(action.displayLabel) { send(action) }
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .buttonStyle(SkimReplyButtonStyle())
                        .disabled(submission.sending || context.disabledReason != nil || state.sentReplyIDs.contains(context.messageID))
                        .help(help(for: action))
                        .accessibilityLabel(action.displayLabel)
                        .accessibilityHint(help(for: action))
                        .accessibilityIdentifier("skim-reply-\(context.messageID)-\(action.id)")
                }
            }
            if submission.sending {
                Text("Sending…")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.secondaryText)
            } else if submission.failed {
                Text("Couldn’t send. Try the reply again.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("skim-reply-error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested replies")
    }

    private func help(for action: SkimReplyAction) -> String {
        if let reason = context.disabledReason { return "\(action.explanation) \(reason)" }
        return action.explanation
    }

    private func send(_ action: SkimReplyAction) {
        Task { @MainActor in
            await submission.send(action, context: context, state: state)
        }
    }
}
