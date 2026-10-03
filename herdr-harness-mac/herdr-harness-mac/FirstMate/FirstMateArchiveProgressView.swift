import SwiftUI

struct FirstMateArchiveProgressView: View {
    let cleanup: FirstMateArchiveCleanup?
    let logs: [FirstMateCleanupLogEntry]
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                if isWorking {
                    ProgressView().controlSize(.small).padding(.top, 3)
                        .accessibilityIdentifier("first-mate-archive-progress")
                } else {
                    Image(systemName: cleanup?.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(cleanup?.status == "completed" ? HerdrTheme.success : HerdrTheme.warning)
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle)
                        .herdrFont(size: 16, weight: .semibold)
                    Text(progressMessage).herdrFont(size: 12)
                        .foregroundStyle(HerdrTheme.secondaryText).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Label(cleanup?.historyAvailable == true ? "Historical record saved" : "Saving history before cleanup",
                      systemImage: cleanup?.historyAvailable == true ? "checkmark.shield" : "doc.text")
                    .herdrFont(size: 12, weight: .medium)
                    .foregroundStyle(cleanup?.historyAvailable == true ? HerdrTheme.success : HerdrTheme.secondaryText)
                if let cleanup {
                    HStack(spacing: 0) {
                        metric(ByteCountFormatter.string(fromByteCount: cleanup.bytesReclaimed, countStyle: .file), label: "Estimated reclaimed")
                        metric("\(cleanup.removed)", label: "Removed")
                        metric("\(cleanup.retained)", label: "Kept")
                        metric("\(cleanup.failed)", label: "Failed", color: cleanup.failed > 0 ? HerdrTheme.alert : HerdrTheme.text)
                    }
                }
            }
            .padding(16).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Activity").herdrFont(size: 14, weight: .semibold)
                    Spacer()
                    Text(isWorking ? "Live updates" : "Saved to history")
                        .herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
                }
                if logs.isEmpty {
                    Text("Waiting for the companion’s first log entry…")
                        .foregroundStyle(HerdrTheme.secondaryText).padding(.vertical, 14)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(logs.reversed())) { entry in
                        FirstMateArchiveLogRow(entry: entry)
                            .padding(.vertical, 13)
                            .herdrHairline(.bottom, color: HerdrTheme.rowDivider)
                    }
                }
                Text("Latest first. Entries stay with the saved record; reclaimed space is a logical size estimate.")
                    .herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .herdrFont(size: 13).foregroundStyle(HerdrTheme.text)
    }

    private var progressMessage: String {
        guard let message = cleanup?.message, !message.isEmpty else { return "Saving the historical record before deleting resources…" }
        return message
    }

    private var statusTitle: String {
        if isWorking { return cleanup?.historyAvailable == true ? "Cleaning up selected resources" : "Saving your history" }
        return cleanup?.status == "completed" ? "Archive complete" : "Archive needs attention"
    }

    private func metric(_ value: String, label: String, color: Color = HerdrTheme.text) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).herdrFont(size: 21, weight: .medium).monospacedDigit().foregroundStyle(color)
            Text(label).herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
