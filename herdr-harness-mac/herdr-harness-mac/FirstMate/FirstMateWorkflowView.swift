import SwiftUI

struct FirstMateWorkflowView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    var openCommit: ((FirstMateGitCommitSelection) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Feature journal").herdrFont(size: 15, weight: .semibold)
                Spacer()
                HerdrTabs(
                    selection: $store.graphMode,
                    tabs: [.init(value: false, title: "Timeline"), .init(value: true, title: "Graph")],
                    style: .compactSegments,
                    accessibilityLabel: "Workflow presentation"
                )
                .fixedSize()
                .accessibilityIdentifier("first-mate-workflow-mode")
            }
            Text("Every visit retains its agents and evidence. Revisions keep earlier work available.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.secondaryText)
            if store.graphMode {
                FirstMateGraphView(store: store, snapshot: snapshot, openCommit: openCommit)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Image(systemName: visit.status == "completed" ? "checkmark.circle.fill" : "circle")
                                    .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                Rectangle().fill(HerdrTheme.hairline).frame(width: 1)
                            }.herdrIconSlot(width: 20)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Text(visit.title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                                    Spacer(minLength: 4)
                                    FirstMateStatusLabel(status: visit.status)
                                }
                                Text("Visit \(index + 1) · revision \(visit.revision)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                                FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                                FirstMateVisitCommitsView(visit: visit, openCommit: openCommit)
                            }.padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            FirstMateReliabilityView(health: store.runtimeHealth, snapshot: snapshot)
            ForEach(snapshot.events.filter { $0.featureID == snapshot.feature.id && $0.recoveryCheckpoint?.workspacePath != nil }.suffix(10)) { event in
                if let checkpoint = event.recoveryCheckpoint {
                    DisclosureGroup("Recovery checkpoint · \(event.createdAt)") {
                        FirstMateRecoveryFactsView(store: store, snapshot: snapshot, checkpoint: checkpoint)
                            .padding(.top, 8)
                    }
                    .herdrFont(size: HerdrTheme.TextSize.small)
                }
            }
            if snapshot.visits.isEmpty {
                ContentUnavailableView("The journey starts with a plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
    }
}

/// Commit receipts remain between this visit's evidence and the next visit.
struct FirstMateVisitCommitsView: View {
    let visit: FirstMateVisit
    var openCommit: ((FirstMateGitCommitSelection) -> Void)?
    @State private var isExpanded = false

    private struct Entry: Identifiable {
        let workspaceID: String
        let commit: FirstMateVisitCommit
        var id: String { workspaceID + "|" + commit.sha }
    }

    private var entries: [Entry] {
        var seen = Set<String>()
        let formatter = ISO8601DateFormatter()
        return (visit.gitEvidence ?? []).flatMap { evidence in
            evidence.commits.map { Entry(workspaceID: evidence.workspaceID, commit: $0) }
        }.filter { seen.insert($0.commit.sha).inserted }
            .sorted {
                (formatter.date(from: $0.commit.committedAt) ?? .distantPast)
                    < (formatter.date(from: $1.commit.committedAt) ?? .distantPast)
            }
    }

    var body: some View {
        let commits = entries
        let primary = visit.primaryGitEvidence.flatMap { evidence in
            evidence.terminalCommit.map { Entry(workspaceID: evidence.workspaceID, commit: $0) }
        } ?? commits.last
        VStack(alignment: .trailing, spacing: 6) {
            if let latest = primary {
                commitButton(latest)
                if commits.count > 1 {
                    Button(isExpanded ? "Hide earlier commits" : "Show all \(commits.count) commits") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    if isExpanded {
                        ForEach(commits.filter { $0.commit.sha != latest.commit.sha }.reversed()) { commitButton($0) }
                    }
                }
                if visit.gitEvidence?.contains(where: \.truncated) == true {
                    Text("Some earlier commits are outside the retained history limit.")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                if visit.gitEvidence?.contains(where: { $0.status != "captured" }) == true {
                    Text("Some workspace commit history is unavailable.")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            } else if ["completed", "superseded", "cancelled"].contains(visit.status) {
                Text(visit.gitEvidence?.isEmpty == false && visit.gitEvidence?.allSatisfy { $0.status == "captured" } == true
                     ? "No commits added" : "Commit history unavailable")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func commitButton(_ entry: Entry) -> some View {
        Button {
            openCommit?(.init(workspaceID: entry.workspaceID, commitSHA: entry.commit.sha))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(String(entry.commit.sha.prefix(8))).monospaced()
                Text(entry.commit.subject).lineLimit(1).truncationMode(.tail)
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
        }
        .buttonStyle(.herdrPlain)
        .foregroundStyle(HerdrTheme.accent)
        .disabled(openCommit == nil)
        .help("Open changes through \(entry.commit.sha): \(entry.commit.subject)")
        .accessibilityLabel("Open commit \(entry.commit.sha): \(entry.commit.subject)")
    }
}
