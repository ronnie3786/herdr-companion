import SwiftUI

struct FirstMateFeatureCapsule: View {
    let conversation: FirstMateConversation
    let fleet: FirstMateMobileFleetStore
    let open: (FirstMateFeatureTarget) -> Void
    @State private var request: FirstMateMobileReadoutRequest?
    var body: some View {
        Button {
            request = .capture(conversation, fleet: fleet)
        } label: {
            HStack(spacing: 6) {
                FirstMateEmojiDisc(emoji: conversation.emoji, size: 20)
                Text(conversation.name).herdrFont(.callout, weight: .semibold).lineLimit(2)
                Circle().fill(FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus)).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(FirstMateChatStatusStyle.tintColor(for: conversation.hudStatus).opacity(0.11), in: .capsule)
            .overlay(Capsule().strokeBorder(FirstMateChatStatusStyle.tintColor(for: conversation.hudStatus).opacity(0.36)))
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(conversation.name), \(FirstMateChatStatusStyle.word(for: conversation)). Opens its readout.")
        .accessibilityIdentifier("first-mate-briefing-feature-\(conversation.machineID)-\(conversation.featureID)")
        .popover(item: $request) { captured in
            FirstMateFeatureReadout(conversation: captured.conversation) {
                guard captured.isCurrent(in: fleet) else { request = nil; return }
                request = nil; open(captured.target)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}
