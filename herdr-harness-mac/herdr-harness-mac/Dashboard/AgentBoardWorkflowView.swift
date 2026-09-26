import SwiftUI

struct AgentBoardWorkflowView: View {
    let content: AgentBoardContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if content.stages.isEmpty {
                    Text("The workflow appears when First Mate plans the first stage.")
                        .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                }
                ForEach(Array(content.stages.enumerated()), id: \.element.id) { index, stage in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(stage))
                            .imageScale(.small)
                            .foregroundStyle(color(stage))
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage.title)
                                .herdrFont(size: HerdrTheme.TextSize.small, weight: stage.isCurrent ? .semibold : .medium)
                                .foregroundStyle(HerdrTheme.primaryText)
                            Text("Stage \(index + 1) · \(stage.statusLabel)")
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .monospacedDigit()
                                .foregroundStyle(stage.isCurrent ? HerdrTheme.accent : HerdrTheme.tertiaryText)
                        }
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(alignment: .topLeading) {
                        if index < content.stages.count - 1 {
                            Rectangle().fill(HerdrTheme.outline)
                                .frame(width: 1)
                                .padding(.top, 20)
                                .padding(.leading, 10)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(_ stage: AgentBoardContent.StageRow) -> String {
        if stage.isCompleted { return "checkmark.circle" }
        if stage.isFailed { return "xmark.circle" }
        if stage.isCurrent { return "circle.inset.filled" }
        return "circle"
    }

    private func color(_ stage: AgentBoardContent.StageRow) -> Color {
        if stage.isCurrent { return content.needsAttention ? HerdrTheme.attention : HerdrTheme.accent }
        if stage.isCompleted { return HerdrTheme.success }
        if stage.isFailed { return HerdrTheme.attention }
        return HerdrTheme.tertiaryText
    }
}
