import SwiftUI

/// Overview's first card: where the feature stands right now. The status
/// word in its color, the step, the six steps as a bar, the one sentence that
/// matters, and where and when it last moved.
struct FirstMateNowCard: View {
    let conversation: FirstMateConversation
    let machineName: String

    private var tint: Color { FirstMateChatStatusStyle.dotColor(for: conversation.hudStatus) }
    private var stepLine: String? {
        if conversation.hudStatus == .done { return "All steps done" }
        guard let index = conversation.stepIndex, FirstMateChatSteps.names.indices.contains(index) else { return nil }
        return "Step \(index + 1) of \(FirstMateChatSteps.names.count), \(FirstMateChatSteps.names[index])"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(FirstMateChatStatusStyle.word(for: conversation))
                    .herdrFont(.title3, weight: .bold)
                    .foregroundStyle(FirstMateChatStatusStyle.color(for: conversation.hudStatus))
                Spacer(minLength: 8)
                if let stepLine {
                    Text(stepLine).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText).lineLimit(1)
                }
            }
            if conversation.stepIndex != nil || conversation.hudStatus == .done {
                FirstMateStepBar(conversation: conversation, tint: tint)
            }
            if let now = conversation.now, !now.isEmpty {
                Text(now).herdrFont(.body).foregroundStyle(HerdrTheme.proseText)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(machineName)
                if let activity = conversation.activityAt {
                    Text("·")
                    Text("updated \(activity.formatted(date: .omitted, time: .shortened))")
                }
            }
            .herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.28)) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-now-card")
    }
}

/// The HUD's six steps as labeled segments, filled through the current one.
struct FirstMateStepBar: View {
    let conversation: FirstMateConversation
    let tint: Color

    private func fill(_ index: Int) -> Double {
        if conversation.hudStatus == .done { return 1 }
        guard let step = conversation.stepIndex else { return 0 }
        if index < step { return 1 }
        if index > step { return 0 }
        return min(1, max(0.08, conversation.stepFraction ?? 0.5))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(FirstMateChatSteps.names.enumerated()), id: \.offset) { index, name in
                let current = conversation.hudStatus != .done && conversation.stepIndex == index
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(HerdrTheme.inkFill(0.10)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(tint).frame(width: proxy.size.width * fill(index))
                            }
                        }
                    Text(name).herdrFont(.caption2, weight: current ? .semibold : .regular)
                        .foregroundStyle(current ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}
