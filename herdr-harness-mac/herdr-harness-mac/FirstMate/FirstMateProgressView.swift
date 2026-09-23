import SwiftUI

struct FirstMateProgressView: View {
    let progress: FirstMateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = progress.summary { Text(summary).herdrFont(.subheadline) }
            if let nextAction = progress.nextAction {
                Text("Next: \(nextAction)").herdrFont(.subheadline, weight: .medium)
            }
            if let evidence = progress.evidence {
                Text("Worker-reported evidence: \(evidence)").herdrFont(.caption).foregroundStyle(.secondary)
            }
            if let recordedAt = progress.recordedAt {
                Text("Checkpoint: \(recordedAt)").herdrFont(.caption2).foregroundStyle(.secondary)
            }
            if let waitUntil = progress.waitUntilEpoch {
                Text("Declared wait until \(Date(timeIntervalSince1970: waitUntil).formatted(date: .abbreviated, time: .shortened))")
                    .herdrFont(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}
