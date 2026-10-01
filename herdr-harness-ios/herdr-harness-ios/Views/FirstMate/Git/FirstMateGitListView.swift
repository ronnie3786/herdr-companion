import SwiftUI

/// The checkout's branch and path, its Staged, Unstaged and Untracked files
/// with stage boxes, and its recent commits.
struct FirstMateGitListView: View {
    let store: FirstMateGitStore
    /// iPhone: rows push their diff (chevrons, no selected row).
    let compact: Bool
    let open: (FirstMateGitSelection) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let status = store.status {
                    branchRow(status)
                    pathRow(status)
                    if let notice = store.notice { noticeBanner(notice) }
                    if status.isClean { cleanCard }
                    ForEach([GitFileSection.staged, .unstaged, .untracked]) { section in
                        let files = status.files(in: section)
                        if !files.isEmpty {
                            sectionHeader(section.label, count: files.count)
                            ForEach(files) { file in
                                FirstMateGitFileRow(store: store, file: file, section: section, compact: compact, open: open)
                            }
                        }
                    }
                    sectionHeader("Recent commits", count: status.commits.count)
                    if status.commits.isEmpty {
                        Text("No commits yet.")
                            .herdrFont(.footnote)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    ForEach(status.commits) { commit in
                        FirstMateGitCommitRow(store: store, commit: commit, compact: compact, open: open)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Changes and commits")
    }

    private func branchRow(_ status: FirstMateGitStatus) -> some View {
        let detached = status.detached == true || status.branch == "HEAD"
        let branch = detached ? "detached HEAD" : (status.branch ?? store.selectedCheckout?.branch ?? "unknown branch")
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(branch)
                .herdrFont(size: 13.5, weight: .semibold, monospaced: true, relativeTo: .subheadline)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.isClean ? "clean" : "\(status.changeCount) changed")
                .herdrFont(size: 12.5, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(status.isClean ? HerdrTheme.success : HerdrTheme.working)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .herdrHairline(.bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Branch \(branch), \(status.isClean ? "clean" : "\(status.changeCount) changed")")
        .accessibilityIdentifier("first-mate-git-branch")
    }

    private func pathRow(_ status: FirstMateGitStatus) -> some View {
        Text(status.rootPath ?? store.selectedCheckout?.path ?? "")
            .herdrFont(size: 12, monospaced: true, relativeTo: .caption)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)
            .accessibilityLabel("Path \(status.rootPath ?? "")")
    }

    private var cleanCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(HerdrTheme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Working tree clean")
                    .herdrFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(HerdrTheme.primaryText)
                Text("Everything in this checkout is committed.")
                    .herdrFont(.footnote)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .herdrCard()
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-git-clean")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HerdrMicroLabel(text: title, count: count)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HerdrTheme.alert)
                .accessibilityHidden(true)
            Text(notice)
                .herdrFont(.footnote)
                .foregroundStyle(HerdrTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.notice = nil
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(HerdrIconButtonStyle(visualSize: 24))
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .herdrCard(fill: HerdrTheme.alert.opacity(0.10), outline: HerdrTheme.alert.opacity(0.35))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-git-notice")
    }
}

/// One changed file: status letter, name over directory, +/− counts once
/// read, and the stage box.
struct FirstMateGitFileRow: View {
    let store: FirstMateGitStore
    let file: WorkspaceGitFile
    let section: GitFileSection
    let compact: Bool
    let open: (FirstMateGitSelection) -> Void

    var body: some View {
        let path = FirstMateGitPath(file.file)
        let letter = section == .untracked ? "?" : FirstMateGitStatusLetter.letter(file.status)
        let counts = store.counts(path: file.file, section: section)
        let selected = !compact && store.selection == .file(path: file.file, section: section)
        let action = FirstMateGitSelectionRules.stageAction(for: section)

        HStack(spacing: 4) {
            Button {
                open(.file(path: file.file, section: section))
            } label: {
                HStack(spacing: 10) {
                    Text(letter)
                        .herdrFont(size: 13, weight: .bold, monospaced: true, relativeTo: .footnote)
                        .foregroundStyle(FirstMateGitColors.status(letter))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(path.name)
                            .herdrFont(size: 14, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(HerdrTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(path.directory.isEmpty ? "." : path.directory)
                            .herdrFont(size: 11.5, monospaced: true, relativeTo: .caption2)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let counts, counts.additions + counts.deletions > 0 {
                        FirstMateGitCounts(additions: counts.additions, deletions: counts.deletions)
                    }
                    if compact {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HerdrTheme.iconTint)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 14)
                .padding(.vertical, 4)
                .frame(minHeight: 50)
                .contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityLabel(rowLabel(name: path.name, directory: path.directory, letter: letter, counts: counts))
            .accessibilityHint(compact ? "Opens the diff" : "Shows the diff")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("first-mate-git-file-\(file.file)")
            .composerLayoutMeasurement(id: "first-mate-git-file-\(section.rawValue)-\(file.file)")

            Button {
                Task { await store.toggleStage(path: file.file, section: section) }
            } label: {
                FirstMateGitStageBox(staged: section == .staged)
            }
            .buttonStyle(.herdrPlain)
            .disabled(store.isMutating)
            .accessibilityLabel("\(action.title) \(path.name)")
            .accessibilityValue(section == .staged ? "Staged" : "Not staged")
            .accessibilityHint(file.file)
            .accessibilityIdentifier("first-mate-git-stage-\(file.file)")
            .composerLayoutMeasurement(id: "first-mate-git-stage-\(section.rawValue)-\(file.file)")
        }
        .padding(.trailing, 6)
        .background(selected ? HerdrTheme.selectedFill : .clear)
    }

    private func rowLabel(name: String, directory: String, letter: String, counts: (additions: Int, deletions: Int)?) -> String {
        var parts = [name, FirstMateGitStatusLetter.word(letter), section.label]
        if let counts {
            parts.append("\(counts.additions) \(counts.additions == 1 ? "addition" : "additions")")
            parts.append("\(counts.deletions) \(counts.deletions == 1 ? "deletion" : "deletions")")
        }
        if !directory.isEmpty { parts.append("in \(directory)") }
        return parts.joined(separator: ", ")
    }
}

/// A 26 pt check box in a 44 pt hit target: filled with a check when staged.
struct FirstMateGitStageBox: View {
    let staged: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(staged ? HerdrTheme.accent : .clear)
            if staged {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(HerdrTheme.onPrimary)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(HerdrTheme.strongOutline, lineWidth: 1.5)
            }
        }
        .frame(width: 26, height: 26)
        .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }
}

struct FirstMateGitCommitRow: View {
    let store: FirstMateGitStore
    let commit: WorkspaceGitCommit
    let compact: Bool
    let open: (FirstMateGitSelection) -> Void

    var body: some View {
        let selected = !compact && store.selection.flatMap(\.commitHash).map {
            FirstMateGitSelectionRules.commit($0, matches: commit.hash)
        } == true
        let short = String(commit.hash.prefix(7))
        Button {
            open(.commit(hash: commit.hash))
        } label: {
            HStack(spacing: 10) {
                Text(short)
                    .herdrFont(size: 12, weight: .medium, monospaced: true, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                Text(commit.message)
                    .herdrFont(size: 13.5, relativeTo: .subheadline)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HerdrTheme.iconTint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .background(selected ? HerdrTheme.selectedFill : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel("Open commit \(short): \(commit.message)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("first-mate-git-commit-\(commit.hash)")
        .composerLayoutMeasurement(id: "first-mate-git-commit-\(commit.hash)")
    }
}

/// "+a −d" in the diff colors.
struct FirstMateGitCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(HerdrTheme.diffAdd)
            Text("−\(deletions)").foregroundStyle(HerdrTheme.diffRemove)
        }
        .herdrFont(size: 12, weight: .semibold, monospaced: true, relativeTo: .caption)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) added, \(deletions) removed")
    }
}

enum FirstMateGitColors {
    /// M and R amber, A green, D red, ? sky; anything else in quiet ink.
    static func status(_ letter: String) -> Color {
        switch letter {
        case "M", "R", "C", "T": HerdrTheme.diffModified
        case "A": HerdrTheme.diffAdd
        case "D": HerdrTheme.diffRemove
        case "?": HerdrTheme.diffUntracked
        case "U": HerdrTheme.alert
        default: HerdrTheme.tertiaryText
        }
    }
}
