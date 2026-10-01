import SwiftUI
import UIKit

/// The diff side: the selected file's diff with its Stage or Unstage button,
/// or a commit with each changed file's diff.
struct FirstMateGitDetailView: View {
    let store: FirstMateGitStore
    let checkoutTitle: String
    /// iPhone: pushed under a navigation bar that already shows the name.
    let compact: Bool

    var body: some View {
        Group {
            switch store.selection {
            case let .file(path, section): fileDetail(path: path, section: section)
            case let .commit(hash): commitDetail(hash)
            case nil:
                FirstMateGitMessage(symbol: "arrow.triangle.branch", title: "Nothing selected",
                                    detail: "Choose a file or a commit.")
            }
        }
        .environment(\.firstMateGitNarrowDiff, compact)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-git-diff")
    }

    // MARK: File

    private func fileDetail(path: String, section: GitFileSection) -> some View {
        let name = FirstMateGitPath(path).name
        let action = FirstMateGitSelectionRules.stageAction(for: section)
        let state = store.diff(path: path, section: section)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    if !compact {
                        Text(name)
                            .herdrFont(size: 15, weight: .semibold, relativeTo: .headline)
                            .foregroundStyle(HerdrTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                    Text(section.label)
                        .herdrFont(size: 11.5, relativeTo: .caption2)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 6))
                        .fixedSize()
                    if let diff = state?.value {
                        FirstMateGitCounts(additions: diff.additions, deletions: diff.deletions)
                    }
                    Spacer(minLength: 8)
                    Button(action.title) {
                        Task { await store.toggleStage(path: path, section: section) }
                    }
                    .buttonStyle(HerdrButtonStyle(kind: .outline, height: 32))
                    .disabled(store.isMutating)
                    .accessibilityLabel("\(action.title) \(name)")
                    .accessibilityIdentifier("first-mate-git-detail-stage")
                    .composerLayoutMeasurement(id: "first-mate-git-detail-stage")
                }
                Text(path)
                    .herdrFont(size: 12, monospaced: true, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)
            .accessibilityElement(children: .contain)

            Group {
                switch state {
                case nil, .loading?:
                    FirstMateGitMessage.loading("Reading the diff…")
                case let .failed(message)?:
                    FirstMateGitMessage(symbol: "exclamationmark.triangle", title: "Diff unavailable", detail: message) {
                        Task { await store.loadDiff(path: path, section: section) }
                    }
                case let .loaded(diff)?:
                    if diff.isEmpty {
                        FirstMateGitMessage(symbol: "doc", title: "No line changes",
                                            detail: "Git reports a change to this file’s mode or metadata only.")
                    } else {
                        FirstMateGitDiffScroll(diff: diff)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Commit

    private func commitDetail(_ hash: String) -> some View {
        let short = String(hash.prefix(7))
        let subject = store.commitSubject(hash)
        let files = store.commitFiles[hash]
        let missing = store.missingCommits.contains(hash)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(short)
                        .herdrFont(size: 12, weight: .medium, monospaced: true, relativeTo: .caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                    Text(subject ?? (missing ? "Commit not found" : "Commit"))
                        .herdrFont(size: 15, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(compact ? 2 : 1)
                }
                .frame(minHeight: 32)
                Text(commitSummary(files))
                    .herdrFont(size: 12, monospaced: true, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Commit \(short): \(subject ?? "unknown"). \(commitSummary(files))")

            Group {
                if missing {
                    FirstMateGitMessage(
                        symbol: "questionmark.circle", title: "Commit not found",
                        detail: "\(short) isn’t in \(checkoutTitle). It may be on another checkout, or outside the history Git keeps here."
                            + (store.showsCheckoutPicker ? " Choose another checkout above." : ""))
                    .accessibilityIdentifier("first-mate-git-commit-missing")
                } else {
                    switch files {
                    case nil, .loading?:
                        FirstMateGitMessage.loading("Reading the commit…")
                    case let .failed(message)?:
                        FirstMateGitMessage(symbol: "exclamationmark.triangle", title: "Commit unavailable", detail: message) {
                            Task { await store.loadCommit(hash) }
                        }
                    case let .loaded(files)?:
                        if files.isEmpty {
                            FirstMateGitMessage(symbol: "doc", title: "No file changes", detail: "This commit changes no files.")
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(files) { file in
                                        commitFile(hash: hash, file: file)
                                    }
                                }
                                .padding(.bottom, 28)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitSummary(_ files: FirstMateGitStore.LoadState<[WorkspaceGitFile]>?) -> String {
        guard let count = files?.value?.count else { return checkoutTitle }
        return "\(count) \(count == 1 ? "file" : "files") changed · \(checkoutTitle)"
    }

    private func commitFile(hash: String, file: WorkspaceGitFile) -> some View {
        let letter = FirstMateGitStatusLetter.letter(file.status)
        let state = store.commitDiff(hash: hash, path: file.file)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(letter)
                    .herdrFont(size: 13, weight: .bold, monospaced: true, relativeTo: .footnote)
                    .foregroundStyle(FirstMateGitColors.status(letter))
                    .frame(width: 16)
                Text(file.file)
                    .herdrFont(size: 13, weight: .semibold, monospaced: true, relativeTo: .footnote)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let diff = state?.value {
                    FirstMateGitCounts(additions: diff.additions, deletions: diff.deletions)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            switch state {
            case nil, .loading?:
                ProgressView()
                    .tint(HerdrTheme.accent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            case let .failed(message)?:
                Text(message)
                    .herdrFont(.footnote)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 18)
            case let .loaded(diff)?:
                if diff.isEmpty {
                    Text("No line changes.")
                        .herdrFont(.footnote)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .padding(.horizontal, 18)
                } else {
                    FirstMateGitDiffBlock(diff: diff)
                }
            }
        }
        .onAppear { store.requestCommitDiff(hash: hash, path: file.file) }
    }
}

// MARK: Diff rendering

extension EnvironmentValues {
    /// iPhone diffs use narrower line-number gutters.
    @Entry var firstMateGitNarrowDiff = false
}

/// Shared metrics: 12.5 pt monospaced code with 46 pt line-number gutters
/// (38 pt on iPhone), both scaled with Dynamic Type.
enum FirstMateGitDiffMetrics {
    static let codeSize: CGFloat = 12.5
    static let trailing: CGFloat = 18

    static func gutter(narrow: Bool) -> CGFloat { narrow ? 38 : 46 }

    /// The width every row takes, so add and remove tints run the full length
    /// of the longest line when the diff scrolls sideways.
    @MainActor
    static func contentWidth(
        for diff: FirstMateGitParsedDiff, minimum: CGFloat, dynamicType: DynamicTypeSize, narrow: Bool
    ) -> CGFloat {
        let size = HerdrFont.scaledSize(codeSize, relativeTo: .footnote, dynamicType: dynamicType)
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let longest = diff.lines.map { $0.text.count + 2 }.max() ?? 0
        let gutters = 2 * HerdrFont.scaledSize(gutter(narrow: narrow), relativeTo: .footnote, dynamicType: dynamicType)
        return max(minimum, ceil(gutters + CGFloat(longest) * advance + trailing + 8))
    }
}

/// A file's diff, scrolling both ways.
struct FirstMateGitDiffScroll: View {
    let diff: FirstMateGitParsedDiff
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.firstMateGitNarrowDiff) private var narrow

    var body: some View {
        GeometryReader { proxy in
            let width = FirstMateGitDiffMetrics.contentWidth(for: diff, minimum: proxy.size.width,
                                                            dynamicType: dynamicType, narrow: narrow)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        FirstMateGitDiffRow(line: line).frame(width: width, alignment: .leading)
                    }
                    if diff.truncated { FirstMateGitTruncatedNote().frame(width: proxy.size.width, alignment: .leading) }
                }
                .padding(.bottom, 28)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .accessibilityLabel("Diff, \(diff.additions) added, \(diff.deletions) removed")
        }
    }
}

/// One file's diff inside a commit: its own sideways scroll.
struct FirstMateGitDiffBlock: View {
    let diff: FirstMateGitParsedDiff
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.firstMateGitNarrowDiff) private var narrow
    @State private var available: CGFloat = 0

    var body: some View {
        let width = FirstMateGitDiffMetrics.contentWidth(for: diff, minimum: available, dynamicType: dynamicType, narrow: narrow)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        FirstMateGitDiffRow(line: line).frame(width: width, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.automatic)
            if diff.truncated { FirstMateGitTruncatedNote() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

struct FirstMateGitTruncatedNote: View {
    var body: some View {
        Label("The companion shows the first 64 KB of this diff.", systemImage: "scissors")
            .herdrFont(.footnote)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
    }
}

/// Old and new line numbers, the +/− marker and the code.
struct FirstMateGitDiffRow: View {
    let line: FirstMateGitDiffLine
    @Environment(\.firstMateGitNarrowDiff) private var narrow
    /// 100 pt scaled with Dynamic Type, so gutters scale like the code.
    @ScaledMetric(relativeTo: .footnote) private var hundred: CGFloat = 100
    @ScaledMetric(relativeTo: .footnote) private var rowHeight: CGFloat = 20.5

    private var gutter: CGFloat { hundred * FirstMateGitDiffMetrics.gutter(narrow: narrow) / 100 }

    private static let addGutter = Color(.sRGB, red: 0, green: 188 / 255, blue: 125 / 255).opacity(0.12)
    private static let removeGutter = Color(.sRGB, red: 1, green: 32 / 255, blue: 86 / 255).opacity(0.12)
    private static let quietNumber = HerdrTheme.foreground.opacity(0.3)

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(verbatim: code)
                .foregroundStyle(codeColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, FirstMateGitDiffMetrics.trailing)
            Spacer(minLength: 0)
        }
        .frame(minHeight: rowHeight)
        .herdrFont(size: FirstMateGitDiffMetrics.codeSize, monospaced: true, relativeTo: .footnote)
        .padding(.top, line.kind == .hunk ? 4 : 0)
        .background(rowFill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .foregroundStyle(numberColor)
            .lineLimit(1)
            .padding(.trailing, 10)
            .frame(width: gutter, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .background(gutterFill)
    }

    private var code: String {
        switch line.kind {
        case .hunk, .note: line.text
        case .added: "+ " + line.text
        case .removed: "− " + line.text
        case .context: "  " + line.text
        }
    }

    private var codeColor: Color {
        switch line.kind {
        case .hunk: HerdrTheme.accent
        case .added, .removed: HerdrTheme.primaryText
        case .context: HerdrTheme.proseText
        case .note: HerdrTheme.tertiaryText
        }
    }

    private var numberColor: Color {
        switch line.kind {
        case .added: HerdrTheme.diffAddNumber
        case .removed: HerdrTheme.diffRemoveNumber
        default: Self.quietNumber
        }
    }

    private var rowFill: Color {
        switch line.kind {
        case .added: HerdrTheme.diffAddRow
        case .removed: HerdrTheme.diffRemoveRow
        case .hunk: HerdrTheme.accent.opacity(0.07)
        case .context, .note: .clear
        }
    }

    private var gutterFill: Color {
        switch line.kind {
        case .added: Self.addGutter
        case .removed: Self.removeGutter
        default: .clear
        }
    }

    private var accessibilityText: String {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        switch line.kind {
        case .hunk: return "Changes from line \(FirstMateGitParsedDiff.hunkStarts(line.text)?.new ?? 0)"
        case .added: return "Added line \(line.newNumber ?? 0): \(text)"
        case .removed: return "Removed line \(line.oldNumber ?? 0): \(text)"
        case .context: return "Line \(line.newNumber ?? 0): \(text)"
        case .note: return text
        }
    }
}
