import SwiftUI

struct FirstMateProgressView: View {
    let progress: FirstMateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = progress.summary, !summary.isEmpty {
                FirstMateMarkdownContentView(source: summary)
                    .environment(\.firstMateMarkdownDensity, .compact)
            }
            if let nextAction = progress.nextAction, !nextAction.isEmpty {
                FirstMateProgressMarkdownField(label: "Next", source: nextAction, emphasis: true)
            }
            if let evidence = progress.evidence, !evidence.isEmpty {
                FirstMateProgressMarkdownField(label: "Worker-reported evidence", source: evidence)
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
