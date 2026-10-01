import SwiftUI

/// A workflow visit's commit receipts, as on the Mac: the visit's latest
/// commit, the rest on request, each opening First Mate Git at that commit.
struct FirstMateVisitCommits: View {
    let visit: FirstMateVisit
    let complete: Bool
    @Environment(\.firstMateInspectorContext) private var context
    @State private var expanded = false

    struct Entry: Identifiable, Equatable {
        let workspaceID: String
        let commit: FirstMateVisitCommit
        var id: String { workspaceID + "|" + commit.sha }
    }

    /// Unique commits across the visit's workspaces, oldest first, and the
    /// one that ended the visit (or the newest).
    static func entries(_ visit: FirstMateVisit) -> (all: [Entry], latest: Entry?) {
        guard let evidence = visit.gitEvidence else { return ([], nil) }
        let formatter = ISO8601DateFormatter()
        var seen = Set<String>()
        let all = evidence.flatMap { item in item.commits.map { Entry(workspaceID: item.workspaceID, commit: $0) } }
            .filter { seen.insert($0.commit.sha).inserted }
            .sorted { (formatter.date(from: $0.commit.committedAt) ?? .distantPast) < (formatter.date(from: $1.commit.committedAt) ?? .distantPast) }
        let terminal = visit.primaryGitEvidence.flatMap { item in item.terminalCommit.map { Entry(workspaceID: item.workspaceID, commit: $0) } }
        return (all, terminal ?? all.last)
    }

    var body: some View {
        let (all, latest) = Self.entries(visit)
        if let latest {
            VStack(alignment: .leading, spacing: 4) {
                commitButton(latest)
                if all.count > 1 {
                    if expanded {
                        ForEach(all.filter { $0.commit.sha != latest.commit.sha }.reversed()) { commitButton($0) }
                    }
                    Button(expanded ? "Hide earlier commits" : "Show all \(all.count) commits") { expanded.toggle() }
                        .buttonStyle(.herdrPlain)
                        .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: 36).contentShape(.rect)
                }
                if visit.gitEvidence?.contains(where: \.truncated) == true {
                    Text("Some earlier commits are outside the retained history limit.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            .padding(.top, 4)
        } else if complete, let evidence = visit.gitEvidence, !evidence.isEmpty {
            Text(evidence.allSatisfy { $0.status == "captured" } ? "No commits added" : "Commit history unavailable")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText).padding(.top, 4)
        }
    }

    private func commitButton(_ entry: Entry) -> some View {
        Button {
            guard let context else { return }
            context.openGit(FirstMateGitTarget(feature: context.target, featureTitle: context.featureTitle,
                                               workspaceID: entry.workspaceID, commitSHA: entry.commit.sha))
        } label: {
            HStack(spacing: 8) {
                Text(String(entry.commit.sha.prefix(8))).font(.system(size: 12, design: .monospaced)).foregroundStyle(HerdrTheme.tertiaryText)
                Text(entry.commit.subject).herdrFont(.footnote).foregroundStyle(HerdrTheme.primaryText).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
            }
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(HerdrTheme.inkFill(0.05), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .disabled(context == nil)
        .accessibilityLabel("Open commit \(entry.commit.sha.prefix(8)) in Git: \(entry.commit.subject)")
        .accessibilityIdentifier("first-mate-commit-\(entry.commit.sha)")
    }
}
