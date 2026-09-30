import SwiftUI

/// A feature that opens its readout: an inline capsule in the briefing, or a
/// Mac lead-Overview row (emoji, name, native status, machine and "now").
struct FirstMateFeatureCapsule: View {
    enum Style { case capsule, row }

    let conversation: FirstMateConversation
    let fleet: FirstMateMobileFleetStore
    var style: Style = .capsule
    var showsMachine = true
    var showsDivider = false
    let open: (FirstMateFeatureTarget) -> Void
    @State private var request: FirstMateMobileReadoutRequest?

    var body: some View {
        Button {
            request = .capture(conversation, fleet: fleet)
        } label: {
            switch style {
            case .capsule: capsule
            case .row: row
            }
        }
        .buttonStyle(.herdrPlain)
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

    private var capsule: some View {
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

    private var detail: String? {
        let now = conversation.now.flatMap { $0.isEmpty ? nil : $0 }
        guard showsMachine else { return now }
        return [conversation.machineName, now].compactMap { $0 }.joined(separator: " · ")
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            FirstMateEmojiDisc(emoji: conversation.emoji, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.name).herdrFont(.body, weight: .medium).foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(FirstMateChatStatusStyle.word(for: conversation))
                        .herdrFont(.footnote, weight: .semibold)
                        .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
                        .lineLimit(1).fixedSize()
                }
                if let detail {
                    Text(detail).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: HerdrTheme.minHitTarget)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1).padding(.leading, 46) }
        }
        .contentShape(.rect)
    }
}
