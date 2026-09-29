import SwiftUI

/// Two-line phone row. Only the list preview is abbreviated; opening the
/// conversation keeps the complete transcript in the existing chat surface.
struct FirstMateConversationRow: View {
    let conversation: FirstMateConversation
    var selected = false
    let open: () -> Void

    private var key: String { "\(conversation.machineID)-\(conversation.featureID)" }
    private var time: String {
        conversation.activityAt.map { FirstMateChatTime.label(for: $0, now: .now, calendar: .current) } ?? ""
    }
    private var status: String { conversation.isArchived ? "Archived" : FirstMateChatStatusStyle.word(for: conversation) }

    var body: some View {
        #if DEBUG
        let _ = FirstMateListPerformanceProbe.bodyEvaluated(conversation.id)
        #endif
        Button(action: open) {
            HStack(spacing: 0) {
                Circle()
                    .fill(FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus))
                    .frame(width: 10, height: 10)
                    .opacity(conversation.showsDot && !conversation.isArchived ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                HStack(spacing: 12) {
                    FirstMateEmojiDisc(emoji: conversation.emoji, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(conversation.name)
                                .herdrFont(.callout, weight: .semibold)
                                .tracking(-0.2)
                                .foregroundStyle(HerdrTheme.primaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .composerLayoutMeasurement(id: "row-name-\(key)", label: conversation.name)
                            if !time.isEmpty {
                                Text(time).herdrFont(.caption).monospacedDigit()
                                    .foregroundStyle(HerdrTheme.tertiaryText)
                                    .fixedSize()
                                    .composerLayoutMeasurement(id: "row-time-\(key)")
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(FirstMateMobileListPresentation.preview(conversation))
                                .herdrFont(.subheadline)
                                .foregroundStyle(conversation.isWorkingOnReply ? HerdrTheme.accent : HerdrTheme.tertiaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .composerLayoutMeasurement(id: "row-preview-\(key)")
                            Text(status)
                                .herdrFont(size: 12, weight: .semibold, relativeTo: .footnote)
                                .foregroundStyle(conversation.isArchived ? HerdrTheme.tertiaryText : FirstMateChatStatusStyle.color(for: conversation.hudStatus))
                                .fixedSize()
                                .firstMateBreathing(conversation.hudStatus == .working && !conversation.isArchived)
                                .composerLayoutMeasurement(id: "row-status-\(key)", label: status)
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 76)
            .contentShape(.rect)
        }
        .buttonStyle(FirstMateConversationButtonStyle(selected: selected))
        .accessibilityLabel("\(conversation.name), \(status)\(conversation.showsDot ? ", new message" : ""), \(conversation.machineName)")
        .accessibilityValue(FirstMateMobileListPresentation.preview(conversation))
        // Keep the existing host-qualified automation identity. The containing
        // list row also has the new conversation namespace, without collisions.
        .accessibilityIdentifier("first-mate-feature-\(key)")
        .composerLayoutMeasurement(id: "row-control-\(key)", label: conversation.name)
        #if DEBUG
        .onAppear { FirstMateListPerformanceProbe.appeared(conversation.id) }
        .onDisappear { FirstMateListPerformanceProbe.disappeared(conversation.id) }
        #endif
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1).padding(.leading, 84)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct FirstMateConversationButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.herdrRowBackground(selected: selected, pressed: configuration.isPressed)
    }
}
