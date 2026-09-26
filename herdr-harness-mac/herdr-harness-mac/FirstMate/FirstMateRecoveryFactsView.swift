import SwiftUI

struct FirstMateRecoveryFactsView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let checkpoint: FirstMateRecoveryCheckpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observed after interruption. These facts do not prove external actions completed; verify before repeating any side effects.")
                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            if let backupPath = checkpoint.backupPath {
                Label("Source recovery archive retained on the companion", systemImage: "archivebox")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                Text(backupPath).herdrFont(size: HerdrTheme.TextSize.caption).monospaced()
                if let checksum = checkpoint.backupSHA256 {
                    Text("SHA-256: \(checksum)").herdrFont(size: HerdrTheme.TextSize.caption).monospaced()
                }
                Text("Tracked changes and non-ignored untracked files only. Never restored automatically.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            if let progress = checkpoint.currentPosition { FirstMateProgressView(progress: progress) }
            if let observedAt = checkpoint.observedAt {
                Text("Observed: \(observedAt)").herdrFont(size: HerdrTheme.TextSize.caption)
            }
            if let workspacePath = checkpoint.workspacePath {
                Text("Workspace: \(workspacePath)").herdrFont(size: HerdrTheme.TextSize.caption)
            }
            if let branch = checkpoint.branch {
                Text(branch.isEmpty ? "Detached HEAD" : "Branch: \(branch)").herdrFont(size: HerdrTheme.TextSize.caption)
            }
            if let head = checkpoint.head {
                Text("HEAD: \(head)").herdrFont(size: HerdrTheme.TextSize.caption).monospaced()
            }
            if let status = checkpoint.workingTreeStatus {
                Text(status.isEmpty ? "Working tree was clean at observation." : status)
                    .herdrFont(size: HerdrTheme.TextSize.caption).monospaced()
            }
            if checkpoint.statusTruncated == true {
                Text("File listing truncated. Inspect the workspace for the complete changes.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            if let observation = checkpoint.workspaceObservation {
                Text(observation).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            if let documentID = checkpoint.handoffDocumentID,
               let document = snapshot.documents.first(where: { $0.id == documentID }) {
                Button("Open latest handoff", systemImage: "doc.text") {
                    Task { await store.open(.document(document)) }
                }
            }
            if let sessionID = checkpoint.nativeSessionID,
               let session = snapshot.sessions.first(where: { $0.nativeSessionID == sessionID }) {
                Button("Open interrupted session", systemImage: "clock.arrow.circlepath") {
                    Task { await store.open(.history(session)) }
                }
            }
        }
        .textSelection(.enabled)
    }
}
