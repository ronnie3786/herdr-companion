import SwiftUI

struct DashboardNowView: View {
    let summary: FirstMateDashboardSummary?
    let needsAttention: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("NOW").tracking(1.6).foregroundStyle(HerdrTheme.accent)
                Spacer(minLength: 4)
                if let summary, let stage = summary.currentStageIndex, stage > 0 {
                    Text(summary.stageCountIsEstimate == true ? "Stage \(stage)" : "Stage \(stage) of \(max(stage, summary.stageCount))")
                        .foregroundStyle(HerdrTheme.mist)
                    if summary.stageCountIsEstimate != true, (1...12).contains(summary.stageCount) {
                        HStack(spacing: 3) {
                            ForEach(0..<summary.stageCount, id: \.self) { index in
                                Capsule().fill(index < stage ? HerdrTheme.accent : HerdrTheme.muted.opacity(0.25))
                                    .frame(width: 9, height: 3)
                            }
                        }.accessibilityHidden(true)
                    }
                }
            }.herdrFont(.caption2)
            Text(summary?.currentStageTitle ?? "Open feature for current focus")
                .herdrFont(.body, weight: needsAttention ? .semibold : .medium)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(HerdrTheme.surface, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
