import AppKit
import SwiftUI

/// The native Git workbench (demo mode, the Git window and First Mate's demo
/// target), drawn as MonoCode's source-control panel beside a unified diff.
///
/// The whole view is opaque `base`: status letters and diff colors are
/// measured against it, and would lose contrast over glass.
struct WorkspaceGitView: View {
    let workspace: HerdrWorkspace
    let loadStatus: () async throws -> WorkspaceGitStatus
    let loadDiff: (String, GitFileSection) async throws -> WorkspaceGitDiffResponse
    let stageFile: (String) async throws -> Void
    let unstageFile: (String) async throws -> Void

    @State private var status: WorkspaceGitStatus?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingFiles: Set<String> = []
    @State private var selectedDiff: WorkspaceGitDiffTarget?
    @State private var hapticPulse = HerdrHapticPulse()
    @Environment(\.herdrFontScale) private var fontScale

    /// MonoCode's 300pt navigator, widened with larger text (up to 420pt) so
    /// names and the branch stay readable.
    private var navigatorWidth: CGFloat {
        min(300 * max(fontScale.rawValue, 1), 420)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                repositoryHeader

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isLoading, status == nil {
                            loadingCard
                        } else if let errorMessage, status == nil {
                            errorCard(errorMessage)
                        } else if let status {
                            gitContent(status)
                        } else {
                            emptyCard(
                                title: "No Git data",
                                detail: "This workspace does not have a Git repository yet.",
                                symbol: PaneDetailMode.git.symbol
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
            }
            .frame(minWidth: 260, idealWidth: navigatorWidth, maxWidth: navigatorWidth, maxHeight: .infinity)
            .herdrHairline(.trailing)

            WorkspaceGitDiffView(
                target: selectedDiff,
                isPending: selectedDiff.map { pendingFiles.contains($0.file) } ?? false,
                loadDiff: loadDiff,
                toggleStaged: { target in mutate(file: target.file, section: target.section) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HerdrTheme.windowBackground)
        .task(id: workspace.id) { await refresh() }
        .herdrHaptic(trigger: hapticPulse)
    }

    /// `.gnav-h` (branch, change count, refresh) over `.gpath` (the root path).
    private var repositoryHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            GitScaledRow(height: HerdrTheme.ControlHeight.bar) {
                HStack(spacing: 8) {
                    Image(systemName: PaneDetailMode.git.symbol)
                        .herdrFont(size: 14)
                        .foregroundStyle(HerdrTheme.iconTint)
                        .accessibilityHidden(true)

                    Text(status?.branch?.nonEmpty ?? workspace.tokens["branch"]?.nonEmpty ?? "detached")
                        .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true, weight: .medium)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    if let status {
                        Text(status.hasChanges ? "\(status.changeCount) changed" : "clean")
                            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(status.hasChanges ? HerdrTheme.working : HerdrTheme.success)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeating, isActive: isLoading)
                    }
                    .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.regular))
                    .disabled(isLoading)
                    .help("Refresh Git")
                    .accessibilityLabel("Refresh Git")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
            }
            .herdrHairline(.bottom)

            Text(status?.cwd?.nonEmpty ?? workspace.displayPath)
                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .herdrHairline(.bottom)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace-git")
    }

    @ViewBuilder
    private func gitContent(_ git: WorkspaceGitStatus) -> some View {
        if let errorMessage {
            errorCard(errorMessage)
        }

        if !git.hasChanges {
            emptyCard(
                title: "Working tree clean",
                detail: "Everything in this workspace is committed.",
                symbol: "checkmark.circle.fill"
            )
        }

        if !git.staged.isEmpty {
            fileSection("Staged", files: git.staged, section: .staged)
        }

        if !git.unstaged.isEmpty {
            fileSection("Unstaged", files: git.unstaged, section: .unstaged)
        }

        if !git.untracked.isEmpty {
            fileSection(
                "Untracked",
                files: git.untracked.map { WorkspaceGitFile(status: "?", file: $0) },
                section: .untracked
            )
        }

        if !git.commits.isEmpty {
            GitSectionHeader(title: "Recent commits", count: git.commits.count, style: .plain)
            ForEach(git.commits) { commit in
                GitCommitRow(commit: commit)
            }
        }
    }

    private func fileSection(_ title: String, files: [WorkspaceGitFile], section: GitFileSection) -> some View {
        GitFileSectionView(
            title: title,
            files: files,
            section: section,
            pendingFiles: pendingFiles,
            selectedDiff: selectedDiff,
            selectDiff: selectDiff,
            mutate: mutate
        )
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.accent)
            Text("Reading workspace Git state…")
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .herdrCard()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// MonoCode's `.attn` recipe in Herdr's alert color.
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Git unavailable", systemImage: "exclamationmark.triangle.fill")
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(HerdrTheme.alert)
            Text(message)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.large))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrCard(
            radius: HerdrTheme.Radius.control,
            fill: HerdrTheme.alert.opacity(0.08),
            outline: HerdrTheme.alert.opacity(0.22)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func emptyCard(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .herdrFont(size: 18)
                .foregroundStyle(symbol.hasPrefix("checkmark") ? HerdrTheme.success : HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.primaryText)
            Text(detail)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 96)
        .herdrCard()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func selectDiff(file: String, section: GitFileSection) {
        selectedDiff = WorkspaceGitDiffTarget(file: file, section: section)
    }

    private func mutate(file: String, section: GitFileSection) {
        guard !pendingFiles.contains(file) else { return }
        pendingFiles.insert(file)
        errorMessage = nil
        Task {
            do {
                if section == .staged {
                    try await unstageFile(file)
                } else {
                    try await stageFile(file)
                }
                await refresh()
                hapticPulse.fire(section == .staged ? .gitUnstaged : .gitStaged)
            } catch {
                errorMessage = error.localizedDescription
                hapticPulse.fire(.failed)
            }
            pendingFiles.remove(file)
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let refreshedStatus = try await loadStatus()
            status = refreshedStatus
            errorMessage = refreshedStatus.error
            reconcileSelection(with: refreshedStatus)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileSelection(with status: WorkspaceGitStatus) {
        let targets = status.staged.map { WorkspaceGitDiffTarget(file: $0.file, section: .staged) }
            + status.unstaged.map { WorkspaceGitDiffTarget(file: $0.file, section: .unstaged) }
            + status.untracked.map { WorkspaceGitDiffTarget(file: $0, section: .untracked) }
        if let selectedDiff, targets.contains(where: { $0.id == selectedDiff.id }) { return }
        selectedDiff = targets.first
    }
}

// MARK: - Navigator

/// A fixed-height Mono row (28pt file rows, 36pt bars) that grows with the
/// font-scale setting so larger text never clips.
private struct GitScaledRow<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: height * fontScale.rawValue, alignment: .leading)
    }
}

private struct GitFileSectionView: View {
    let title: String
    let files: [WorkspaceGitFile]
    let section: GitFileSection
    let pendingFiles: Set<String>
    let selectedDiff: WorkspaceGitDiffTarget?
    let selectDiff: (String, GitFileSection) -> Void
    let mutate: (String, GitFileSection) -> Void

    var body: some View {
        GitSectionHeader(title: title, count: files.count, style: .badge)
        ForEach(files) { file in
            GitFileRow(
                file: file,
                section: section,
                isPending: pendingFiles.contains(file.file),
                isSelected: selectedDiff?.id == WorkspaceGitDiffTarget(file: file.file, section: section).id,
                selectDiff: selectDiff,
                mutate: mutate
            )
        }
    }
}

/// `.gsec`: a 10pt uppercase label with a lavender count badge (file
/// sections) or a plain trailing count (recent commits).
private struct GitSectionHeader: View {
    enum Style { case badge, plain }

    let title: String
    let count: Int
    let style: Style

    var body: some View {
        GitScaledRow(height: HerdrTheme.ControlHeight.large) {
            HStack(spacing: 6) {
                HerdrMicroLabel(text: title)
                switch style {
                case .badge:
                    HerdrCountBadge(count: count, style: .accent)
                case .plain:
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// `.gfile`: file-type glyph, name, folder, a stage/unstage action revealed
/// on hover or selection, and the colored status letter.
private struct GitFileRow: View {
    let file: WorkspaceGitFile
    let section: GitFileSection
    let isPending: Bool
    let isSelected: Bool
    let selectDiff: (String, GitFileSection) -> Void
    let mutate: (String, GitFileSection) -> Void

    @State private var isHovering = false

    var body: some View {
        GitScaledRow(height: HerdrTheme.ControlHeight.large) {
            HStack(spacing: 6) {
                Button {
                    selectDiff(file.file, section)
                } label: {
                    HStack(spacing: 6) {
                        GitFileGlyph(path: file.file)
                        GitFileName(path: file.file)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(file.file)
                .accessibilityLabel("View diff for \(file.file)")

                action

                Text(file.status)
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true, weight: .semibold)
                    .foregroundStyle(GitStatusLetter.color(for: file.status))
                    .lineLimit(1)
                    .frame(minWidth: 14, alignment: .trailing)
                    .fixedSize()
                    .accessibilityLabel(GitStatusLetter.label(for: file.status))
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
        }
        .herdrRowBackground(selected: isSelected, hovered: isHovering, radius: 0)
        .onHover { isHovering = $0 }
    }

    /// Always in the accessibility tree; drawn and clickable only while the
    /// row is hovered or selected, or while its request is in flight.
    @ViewBuilder
    private var action: some View {
        let revealed = isHovering || isSelected || isPending
        let title = section == .staged ? "Unstage" : "Stage"
        Button {
            mutate(file.file, section)
        } label: {
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .tint(HerdrTheme.accent)
            } else {
                Label(title, systemImage: section == .staged ? "minus" : "plus")
            }
        }
        .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.mini))
        .disabled(isPending)
        .opacity(revealed ? 1 : 0)
        .allowsHitTesting(revealed)
        .help("\(title) \(file.file)")
        .accessibilityLabel("\(title) \(file.file)")
    }
}

/// The last path component (13pt/500) followed by its folder (11pt
/// tertiary); the folder truncates first so the name stays readable.
private struct GitFileName: View {
    let path: String

    var body: some View {
        let parts = GitPathParts(path)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.name)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let folder = parts.folder {
                Text(folder)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private struct GitPathParts {
    let name: String
    let folder: String?

    init(_ path: String) {
        if let slash = path.lastIndex(of: "/") {
            name = String(path[path.index(after: slash)...])
            let folder = String(path[..<slash])
            self.folder = folder.isEmpty ? nil : folder
        } else {
            name = path
            folder = nil
        }
    }
}

/// A 14pt file-type glyph: Swift's bird for Swift sources, a page otherwise.
private struct GitFileGlyph: View {
    let path: String
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        let isSwift = path.lowercased().hasSuffix(".swift")
        Image(systemName: isSwift ? "swift" : "doc.text")
            .herdrFont(size: 13, weight: .semibold)
            .foregroundStyle(isSwift ? HerdrTheme.Syntax.type : HerdrTheme.iconTint)
            .frame(width: 16 * fontScale.rawValue)
            .accessibilityHidden(true)
    }
}

/// MonoCode's status letters: M amber, ? sky, A emerald, D rose.
enum GitStatusLetter {
    static func color(for status: String) -> Color {
        switch status.first {
        case "M", "R", "C", "T": HerdrTheme.diffModified
        case "?": HerdrTheme.diffUntracked
        case "A": HerdrTheme.diffAdd
        case "D", "U": HerdrTheme.diffRemove
        default: HerdrTheme.tertiaryText
        }
    }

    static func label(for status: String) -> String {
        switch status.first {
        case "M": "Modified"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        case "?": "Untracked"
        case "A": "Added"
        case "D": "Deleted"
        case "U": "Unmerged"
        default: status
        }
    }
}

/// `.gcommit`: short hash (11pt mono tertiary) and a one-line message.
private struct GitCommitRow: View {
    let commit: WorkspaceGitCommit

    var body: some View {
        GitScaledRow(height: HerdrTheme.ControlHeight.large) {
            HStack(spacing: 10) {
                Text(commit.hash)
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()

                Text(commit.message)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
        }
        .help(commit.message)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Diff

private struct WorkspaceGitDiffTarget: Identifiable {
    let file: String
    let section: GitFileSection

    var id: String { "\(section.rawValue)|\(file)" }
}

private struct WorkspaceGitDiffView: View {
    let target: WorkspaceGitDiffTarget?
    let isPending: Bool
    let loadDiff: (String, GitFileSection) async throws -> WorkspaceGitDiffResponse
    let toggleStaged: (WorkspaceGitDiffTarget) -> Void

    @State private var parsed: WorkspaceGitParsedDiff?
    @State private var errorMessage: String?
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            if let target {
                fileHeader(target)
            }

            ZStack {
                if target == nil {
                    ContentUnavailableView(
                        "Select a changed file",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Its diff will stay open here while you browse the repository.")
                    )
                    .foregroundStyle(HerdrTheme.primaryText)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Diff unavailable",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(errorMessage)
                    )
                    .foregroundStyle(HerdrTheme.primaryText)
                } else if let parsed {
                    WorkspaceGitDiffRows(parsed: parsed)
                } else {
                    ProgressView("Loading diff…")
                        .controlSize(.small)
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .tint(HerdrTheme.accent)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: target?.id) {
            parsed = nil
            errorMessage = nil
            guard let target else { return }
            do {
                let response = try await loadDiff(target.file, target.section)
                if let responseError = response.error {
                    errorMessage = responseError
                } else {
                    let diff = response.diff?.nonEmpty ?? "(empty diff)"
                    let file = target.file
                    let result = await Task.detached(priority: .userInitiated) {
                        WorkspaceGitDiffParser.parse(diff, file: file)
                    }.value
                    try Task.checkCancellation()
                    parsed = result
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff")
    }

    /// `.gdiff-top`: "Staged · 1 file" with the diff's +/− counts. It shares
    /// the navigator header's 36pt height so their hairlines line up.
    private var summaryBar: some View {
        GitScaledRow(height: HerdrTheme.ControlHeight.bar) {
            HStack(spacing: 12) {
                Text(target.map { "\($0.section.label) · 1 file" } ?? "Code changes")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(1)
                if target != nil, let parsed {
                    GitChangeCounts(additions: parsed.additions, deletions: parsed.deletions)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
        }
        .herdrHairline(.bottom)
        .accessibilityElement(children: .combine)
    }

    /// `.dfh`: the file path on a 2% wash with its counts and a stage box.
    private func fileHeader(_ target: WorkspaceGitDiffTarget) -> some View {
        HStack(spacing: 8) {
            GitFileGlyph(path: target.file)
            Text(target.file)
                .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                .foregroundStyle(HerdrTheme.inkSolid(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(target.file)
            Spacer(minLength: 8)
            if let parsed {
                GitChangeCounts(additions: parsed.additions, deletions: parsed.deletions)
            }
            GitStageBox(
                isStaged: target.section == .staged,
                isPending: isPending,
                file: target.file,
                toggle: { toggleStaged(target) }
            )
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(HerdrTheme.inkFill(0.02))
        .herdrHairline(.bottom)
    }
}

/// `+N −N` in MonoCode's count colors, 11pt/600 with tabular digits.
private struct GitChangeCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(HerdrTheme.diffAdd)
            Text("\u{2212}\(deletions)").foregroundStyle(HerdrTheme.diffRemove)
        }
        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) added, \(deletions) removed")
    }
}

/// The file header's 16pt stage checkbox (ink box with a base check when
/// staged, a 15% ring otherwise) on a 28pt hit area.
private struct GitStageBox: View {
    let isStaged: Bool
    let isPending: Bool
    let file: String
    let toggle: () -> Void

    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        let size = 16 * fontScale.rawValue
        Button(action: toggle) {
            ZStack {
                if isPending {
                    ProgressView().controlSize(.mini)
                } else if isStaged {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(HerdrTheme.primaryText)
                    Image(systemName: "checkmark")
                        .herdrFont(size: 10, weight: .bold)
                        .foregroundStyle(HerdrTheme.base)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(HerdrTheme.strongOutline, lineWidth: 1)
                }
            }
            .frame(width: size, height: size)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help(isStaged ? "Unstage \(file)" : "Stage \(file)")
        .accessibilityLabel("Staged")
        .accessibilityValue(isStaged ? "On" : "Off")
        .accessibilityHint(isStaged ? "Unstages \(file)" : "Stages \(file)")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The unified diff body: 20pt rows with a 48pt number gutter, 22pt hunk
/// bars and 32pt fold bars, all multiplied by the font-scale setting.
private struct WorkspaceGitDiffRows: View {
    let parsed: WorkspaceGitParsedDiff

    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        let metrics = GitDiffMetrics(scale: fontScale.rawValue, longestLine: parsed.longestLine)
        GeometryReader { proxy in
            let width = max(proxy.size.width, metrics.contentWidth)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed.rows) { row in
                        GitDiffRowView(row: row, metrics: metrics)
                            .frame(width: width, alignment: .leading)
                    }
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading, for: .alignment)
        }
    }
}

private struct GitDiffMetrics {
    let scale: Double
    let gutter: CGFloat
    let row: CGFloat
    let hunk: CGFloat
    let fold: CGFloat
    let contentWidth: CGFloat

    init(scale: Double, longestLine: Int) {
        self.scale = scale
        gutter = 48 * scale
        row = 20 * scale
        hunk = 22 * scale
        fold = 32 * scale
        let font = NSFont.monospacedSystemFont(ofSize: HerdrTheme.TextSize.small * scale, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        contentWidth = gutter + 24 + CGFloat(longestLine) * advance
    }

    /// Where code starts: past the gutter and the code's 12pt inset.
    var codeInset: CGFloat { gutter + 12 }
}

private struct GitDiffRowView: View {
    let row: WorkspaceGitDiffRow
    let metrics: GitDiffMetrics

    var body: some View {
        switch row.kind {
        case .hunk:
            bar(height: metrics.hunk, fill: HerdrTheme.insetFill, text: row.text)
        case let .fold(count):
            bar(height: metrics.fold, fill: HerdrTheme.chipFill, text: "\(count) unmodified \(count == 1 ? "line" : "lines")")
                .accessibilityLabel(row.accessibilityLabel)
        case .note, .marker:
            Text(row.text.isEmpty ? " " : row.text)
                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .padding(.leading, row.kind == .marker ? metrics.codeInset : 12)
                .frame(minHeight: metrics.row, alignment: .leading)
        case .context, .addition, .deletion:
            codeRow
        }
    }

    private func bar(height: CGFloat, fill: Color, text: String) -> some View {
        Text(text)
            .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
            .foregroundStyle(HerdrTheme.diffHunk)
            .lineLimit(1)
            .padding(.leading, metrics.codeInset)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(fill)
    }

    private var codeRow: some View {
        HStack(spacing: 0) {
            Text(row.number.map(String.init) ?? "")
                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                .monospacedDigit()
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .padding(.trailing, 8)
                .frame(width: metrics.gutter, alignment: .trailing)
                .frame(maxHeight: .infinity)
                .background(gutterFill)
                .accessibilityHidden(true)

            code
                .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                .foregroundStyle(codeColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.row, alignment: .leading)
        .background(rowFill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var code: Text {
        if let highlighted = row.highlighted {
            return Text(highlighted)
        }
        return Text(row.text.isEmpty ? " " : row.text)
    }

    private var rowFill: Color {
        switch row.kind {
        case .addition: HerdrTheme.diffAddRow
        case .deletion: HerdrTheme.diffRemoveRow
        default: .clear
        }
    }

    private var gutterFill: Color {
        switch row.kind {
        case .addition: HerdrTheme.diffAddGutter
        case .deletion: HerdrTheme.diffRemoveGutter
        default: .clear
        }
    }

    private var numberColor: Color {
        switch row.kind {
        case .addition: HerdrTheme.diffAddNumber
        case .deletion: HerdrTheme.diffRemoveNumber
        default: HerdrTheme.tertiaryText
        }
    }

    /// Changed code reads at ink 80%; context steps back to secondary text.
    private var codeColor: Color {
        switch row.kind {
        case .addition, .deletion: HerdrTheme.inkSolid(0.80)
        default: HerdrTheme.secondaryText
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
