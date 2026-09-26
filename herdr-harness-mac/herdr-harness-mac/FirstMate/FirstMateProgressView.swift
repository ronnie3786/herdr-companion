import SwiftUI

struct FirstMateProgressView: View {
    let progress: FirstMateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = progress.summary { Text(summary).herdrFont(size: HerdrTheme.TextSize.small) }
            if let nextAction = progress.nextAction {
                Text("Next: \(nextAction)").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
            }
            if let evidence = progress.evidence {
                Text("Worker-reported evidence: \(evidence)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            if let recordedAt = progress.recordedAt {
                Text("Checkpoint: \(recordedAt)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            if let waitUntil = progress.waitUntilEpoch {
                Text("Declared wait until \(Date(timeIntervalSince1970: waitUntil).formatted(date: .abbreviated, time: .shortened))")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .textSelection(.enabled)
    }
}
