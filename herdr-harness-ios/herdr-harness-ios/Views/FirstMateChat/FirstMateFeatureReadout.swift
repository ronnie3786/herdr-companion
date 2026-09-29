import SwiftUI

struct FirstMateFeatureReadout: View {
    let conversation: FirstMateConversation
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FirstMateEmojiDisc(emoji: conversation.emoji, size: 32)
                Text(conversation.name).herdrFont(.body, weight: .semibold)
            }
            Text(FirstMateChatStatusStyle.word(for: conversation)).herdrFont(.footnote)
                .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
            Text(conversation.now ?? "No current step reported.")
                .herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(0..<6) { step in
                    Capsule().fill(step <= (conversation.stepIndex ?? -1) ? HerdrTheme.accent : HerdrTheme.codeFill).frame(height: 3)
                }
            }.accessibilityHidden(true)
            if let step = FirstMateChatStatusStyle.stepText(for: conversation) {
                Text(step).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            } else { Text("Step not reported").herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText) }
            Text(conversation.machineName).herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText)
            Button("Open chat", action: open).buttonStyle(HerdrButtonStyle(kind: .primary))
                .accessibilityIdentifier("first-mate-readout-open")
        }
        .padding(16).frame(width: 300, alignment: .leading)
        .foregroundStyle(HerdrTheme.primaryText).background(HerdrTheme.base)
        .herdrFirstMateChrome().accessibilityElement(children: .contain).accessibilityIdentifier("first-mate-feature-readout")
    }
}
