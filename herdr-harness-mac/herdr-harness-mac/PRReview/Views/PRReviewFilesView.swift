import AppKit
import SwiftUI

struct PRReviewFilesView: View {
    @Bindable var store: PRReviewStore
    var canControl = false
    var questionHistory: PRReviewQuestionHistory?
    var openQuestion: (PRReviewQuestionHistory.Question) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Group {
            switch presentation {
            case .preparing:
                unavailable(
                    "Preparing this review",
                    detail: "Herdr is fetching the pull request and building its native diff.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            case .loading:
                unavailable(
                    "Loading changed files",
                    detail: "Fetching this review’s latest file list.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            case let .failed(message):
                unavailable(
                    "Review preparation failed",
                    detail: message,
                    systemImage: "exclamationmark.triangle",
                    retry: canControl
                )
            case .noFiles:
                unavailable(
                    "No changed files",
                    detail: "This ready review did not report any changed files.",
                    systemImage: "doc"
                )
            case .content, .noFilterMatches:
                filesAndDiff
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selectFirstFileIfNeeded() }
        .onChange(of: store.orderedFiles.map(\.path)) { _, _ in selectFirstFileIfNeeded() }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), let previous = store.previousFile() else { return .ignored }
            store.selectedPath = previous.path
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), let next = store.nextFile() else { return .ignored }
            store.selectedPath = next.path
            return .handled
        }
        .onKeyPress("v", phases: .down) { press in
            guard press.modifiers.contains(.option), let path = store.selectedPath,
                  let file = store.orderedFiles.first(where: { $0.path == path })
            else { return .ignored }
            Task { await store.setViewed(paths: [path], viewed: !file.viewed) }
            return .handled
        }
    }

    private var filesAndDiff: some View {
        HSplitView {
            VStack(spacing: 0) {
                controls
                if presentation == .noFilterMatches {
                    ContentUnavailableView {
                        Label("No matching files", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Change the impact, viewed, or text filters.")
                    } actions: {
                        Button("Clear filters", action: clearFilters)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier("pr-review-no-filter-matches")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.orderedFiles.enumerated()), id: \.element.id) { index, file in
                                PRReviewFileRow(file: file, index: index, selected: file.path == store.selectedPath,
                                                guided: store.viewMode == .guided) {
                                    store.selectedPath = file.path
                                } setViewed: { viewed in
                                    Task { await store.setViewed(paths: [file.path], viewed: viewed) }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(
                minWidth: PRReviewFilesLayout.minimumRailWidth,
                idealWidth: PRReviewFilesLayout.idealRailWidth,
                maxWidth: PRReviewFilesLayout.maximumRailWidth,
                maxHeight: .infinity,
                alignment: .top
            )
            PRReviewDiffView(
                store: store,
                questionHistory: questionHistory,
                openQuestion: openQuestion,
                openURL: openURL,
                askAI: askAI,
                questionDraftChanged: questionDraftChanged
            )
                .frame(minWidth: PRReviewFilesLayout.minimumDiffWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Order", selection: $store.viewMode) {
                Text("GitHub order").tag(PRReviewViewMode.github)
                Text("Guided").tag(PRReviewViewMode.guided)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pr-review-view-mode")
            HStack {
                Picker("Impact", selection: $store.impactFilter) {
                    ForEach(PRReviewImpactFilter.allCases, id: \.self) { impact in
                        Text(impact.rawValue.capitalized).tag(impact)
                    }
                }
                .accessibilityIdentifier("pr-review-impact-filter")
                Toggle("Hide viewed", isOn: $store.hideViewed).herdrFont(.caption)
            }
            TextField("Filter files", text: $store.search).textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(HerdrTheme.ink)
    }

    private func selectFirstFileIfNeeded() {
        // `refresh()` publishes the review summaries before its snapshot
        // arrives, so the mounted view briefly sees an empty file list.
        // Normalizing against that temporary emptiness would drop a pop-out's
        // seeded selection before its files load; wait for the snapshot.
        guard store.snapshot != nil else { return }
        if store.selectedPath == nil || !store.orderedFiles.contains(where: { $0.path == store.selectedPath }) {
            store.selectedPath = store.orderedFiles.first?.path
        }
    }

    private var presentation: PRReviewFilesPresentation {
        PRReviewFilesPresentation.resolve(
            status: store.snapshot?.review.status ?? store.selectedReview?.status,
            reviewError: store.snapshot?.review.error ?? store.selectedReview?.error,
            hasSnapshot: store.snapshot != nil,
            fileCount: store.snapshot?.files.count ?? 0,
            visibleFileCount: store.orderedFiles.count
        )
    }

    private func clearFilters() {
        store.impactFilter = .all
        store.hideViewed = false
        store.search = ""
    }

    private func unavailable(
        _ title: String,
        detail: String,
        systemImage: String,
        retry: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            if retry {
                Button("Retry") { Task { await store.refreshReview() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("pr-review-files-state")
    }
}

enum PRReviewFilesLayout {
    static let minimumRailWidth: CGFloat = 260
    static let idealRailWidth: CGFloat = 300
    static let maximumRailWidth: CGFloat = 380
    static let minimumDiffWidth: CGFloat = 440
}

enum PRReviewFilesPresentation: Equatable {
    case loading
    case preparing
    case failed(String)
    case noFiles
    case noFilterMatches
    case content

    static func resolve(
        status: PRReviewStatus?,
        reviewError: String?,
        hasSnapshot: Bool,
        fileCount: Int,
        visibleFileCount: Int
    ) -> Self {
        // A refresh failure must not hide a review that is already readable,
        // including snapshots returned by older companion versions.
        if fileCount == 0 {
            if status == .preparing { return .preparing }
            if status == .failed { return .failed(reviewError ?? "The companion could not prepare this review.") }
        }
        if !hasSnapshot { return .loading }
        if fileCount == 0 { return .noFiles }
        if visibleFileCount == 0 { return .noFilterMatches }
        return .content
    }
}

/// Copy and accessibility values for the deleted-file disclosure. Keeping the
/// presentation in one value type lets the row, the selected-file header, and
/// tests agree on the exact wording without relying on color.
enum PRReviewDeletedFileDisclosure {
    static let badgeLabel = "Deleted"
    static let showLabel = "Show deleted content"
    static let hideLabel = "Hide deleted content"
    static let expandedValue = "Expanded"
    static let collapsedValue = "Collapsed"
    static let accessibilityIdentifier = "pr-review-deleted-content-disclosure"

    static func actionLabel(expanded: Bool) -> String {
        expanded ? hideLabel : showLabel
    }

    static func stateDescription(expanded: Bool) -> String {
        expanded ? expandedValue : collapsedValue
    }

    /// A compact, textual deletion summary that stays readable without color.
    static func summary(deletions: Int) -> String {
        deletions == 1 ? "Deleted · 1 line removed" : "Deleted · \(deletions) lines removed"
    }

    static func hiddenDetail(deletions: Int) -> String {
        deletions == 1
            ? "1 removed line is hidden. Choose Show deleted content to inspect it."
            : "\(deletions) removed lines are hidden. Choose Show deleted content to inspect them."
    }

    /// Keeping content and a nonempty Ask AI draft are mutually exclusive:
    /// hiding while the reviewer is typing would discard their question.
    static func canToggle(expanded: Bool, hasQuestionDraft: Bool) -> Bool {
        !(expanded && hasQuestionDraft)
    }
}

/// A text badge, so the deleted state never depends on red coloring alone.
struct PRReviewDeletedIndicator: View {
    var accessibilityIdentifier: String

    var body: some View {
        Text(PRReviewDeletedFileDisclosure.badgeLabel)
            .herdrFont(.caption2, weight: .semibold)
            .foregroundStyle(HerdrTheme.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(HerdrTheme.elevated, in: .capsule)
            .fixedSize()
            .accessibilityLabel("Deleted file")
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct PRReviewFileRow: View {
    let file: PRReviewFile
    let index: Int
    let selected: Bool
    let guided: Bool
    let select: () -> Void
    let setViewed: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(impactColor).frame(width: 8, height: 8).help(file.impactReason ?? "Not ranked")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                        .herdrFont(.subheadline, weight: .semibold).lineLimit(1)
                    if file.isDeleted {
                        PRReviewDeletedIndicator(accessibilityIdentifier: "pr-review-file-deleted-\(index)")
                    }
                }
                Text(directoryHint).herdrFont(.caption2).foregroundStyle(HerdrTheme.mist).lineLimit(1).truncationMode(.head)
                if guided, let order = file.guidedOrder {
                    Text("#\(order) · \(file.guidedReason ?? "Guided review order")")
                        .herdrFont(.caption2).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("+\(file.additions) −\(file.deletions)").herdrFont(.caption2, monospacedDigit: true).foregroundStyle(HerdrTheme.mist)
            Toggle("Viewed", isOn: Binding(get: { file.viewed }, set: setViewed)).labelsHidden()
                .accessibilityIdentifier("pr-review-viewed-\(index)")
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(selected ? HerdrTheme.selection : .clear, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .help(file.path)
        .onTapGesture(perform: select)
        .accessibilityIdentifier("pr-review-file-\(index)")
    }

    private var directoryHint: String {
        let components = file.path.split(separator: "/")
        return components.dropLast().joined(separator: "/")
    }

    private var impactColor: Color {
        switch file.impact {
        case .high: HerdrTheme.alert
        case .medium: HerdrTheme.working
        case .low: HerdrTheme.signal
        case .unknown, nil: HerdrTheme.muted
        }
    }
}

struct PRReviewDiffView: View {
    @Bindable var store: PRReviewStore
    var questionHistory: PRReviewQuestionHistory?
    var openQuestion: (PRReviewQuestionHistory.Question) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }
    @State private var hasQuestionDraft = false

    private var file: PRReviewFile? { store.snapshot?.files.first { $0.path == store.selectedPath } }
    private var currentDiff: PRReviewDiff? {
        guard let diff = store.diff,
              let review = store.snapshot?.review ?? store.selectedReview,
              diff.reviewID.isEmpty || diff.reviewID == review.id,
              review.baseSHA.isEmpty || diff.baseSHA == review.baseSHA,
              review.headSHA.isEmpty || diff.headSHA == review.headSHA
        else { return nil }
        return diff
    }
    private var diffFile: PRReviewDiffFile? { currentDiff?.files.first { $0.path == store.selectedPath } }

    var body: some View {
        VStack(spacing: 0) {
            if let file {
                header(file)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = store.currentDiffLoadError {
                    unavailable("Couldn’t load this diff", detail: message, retry: true)
                } else if let diffFile {
                    if diffFile.binary {
                        unavailable("Binary file", detail: "A native text diff is not available for this file.")
                    } else if diffFile.hunks.isEmpty {
                        unavailable(
                            "No textual changes",
                            detail: diffFile.truncated || currentDiff?.truncated == true
                                ? "The available patch is partial and contains no text for this file."
                                : "The companion did not report any textual hunks for this file."
                        )
                    } else {
                        if diffFile.truncated || currentDiff?.truncated == true { partialDiffWarning }
                        if deletedContentIsHidden {
                            deletedContentHidden(file)
                        } else {
                            diffText(diffFile)
                        }
                    }
                } else if store.completedDiffIdentity == store.currentDiffRequestIdentity {
                    unavailable(
                        "No diff for this file",
                        detail: "The companion completed the request without a matching textual file diff.",
                        retry: true
                    )
                } else {
                    unavailable("Loading diff", detail: "Fetching the native unified diff for this file.")
                }
            } else {
                ContentUnavailableView("Select a changed file", systemImage: "doc")
            }
            if let machineID = store.currentMachineID, let reviewID = store.selectedReviewID,
               let questionHistory {
                let questions = questionHistory.questions(machineID: machineID, reviewID: reviewID)
                if !questions.isEmpty {
                    PRReviewQuestionRail(questions: questions,
                                         baseSHA: store.snapshot?.review.baseSHA ?? "",
                                         headSHA: store.snapshot?.review.headSHA ?? "", open: openQuestion)
                }
                if let error = questionHistory.loadError {
                    Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.alert).padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: store.currentDiffRequestIdentity) { await loadDiff() }
        .onChange(of: store.scrollRequest?.token) { _, _ in
            guard let request = store.scrollRequest else { return }
            store.selectedPath = request.path
            store.revealDeletedContent(path: request.path)
        }
        .onChange(of: highlightIdentity) { _, _ in
            guard let path = store.highlight?.path else { return }
            store.revealDeletedContent(path: path)
        }
        .onChange(of: store.selectedPath) { _, _ in
            hasQuestionDraft = false
            store.visibleLines = nil
        }
        .onChange(of: codeContentVisible) { _, visible in
            if !visible { store.visibleLines = nil }
        }
    }

    private var partialDiffWarning: some View {
        HStack(spacing: 8) {
            Label(partialDiffWarningText, systemImage: "exclamationmark.triangle")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.working)
            Spacer()
            Button("Open full diff on GitHub", action: openFullDiff)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(HerdrTheme.elevated)
        .accessibilityIdentifier("pr-review-partial-diff")
    }

    private var partialDiffWarningText: String {
        deletedContentIsHidden
            ? "Partial diff. Removed code is hidden until you show deleted content."
            : "Partial diff. Available code is shown below."
    }

    private func header(_ file: PRReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(file.path).herdrFont(.headline).lineLimit(1).help(file.path)
                        if selectedFileIsDeleted {
                            PRReviewDeletedIndicator(accessibilityIdentifier: "pr-review-deleted-indicator")
                        }
                    }
                    Text(headerSummary(file)).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
            }
            Text(file.impactExplanation)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(3)
                .help(file.impactExplanation)
                .accessibilityIdentifier("pr-review-impact-reason")
            if store.viewMode == .guided, let order = file.guidedOrder {
                Text("Guided order #\(order) · \(file.guidedReason ?? "Review this file next")")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if showsDeletedContentDisclosure {
                    deletedContentDisclosureButton(file)
                }
                Spacer()
                Button("Previous") { store.selectedPath = store.previousFile()?.path }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Next") { store.selectedPath = store.nextFile()?.path }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Button(file.viewed ? "Mark unviewed" : "Mark viewed") {
                    Task { await store.setViewed(paths: [file.path], viewed: !file.viewed) }
                }
                .keyboardShortcut("v", modifiers: .option)
                Button("GitHub", action: openFullDiff)
            }
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(HerdrTheme.ink)
    }

    private var highlight: (start: Int, end: Int, side: PRReviewSide)? {
        guard let highlight = store.highlight, highlight.path == store.selectedPath else { return nil }
        return (highlight.start, highlight.end, highlight.side)
    }

    private var highlightIdentity: String? {
        guard let highlight = store.highlight else { return nil }
        return "\(highlight.path)\u{1f}\(highlight.side.rawValue)\u{1f}\(highlight.start)\u{1f}\(highlight.end)"
    }

    private var selectedFileIsDeleted: Bool {
        guard let path = store.selectedPath else { return false }
        return store.isDeletedFile(path: path)
    }

    /// True when the selected file is deleted and its removed lines are hidden.
    private var deletedContentIsHidden: Bool {
        guard file != nil, selectedFileIsDeleted, let path = store.selectedPath else { return false }
        return !store.isDeletedContentExpanded(path: path)
    }

    /// A deleted binary or hunk-less diff has nothing textual to disclose, so
    /// its honest message stands alone instead of offering a control with no
    /// effect. While the diff is still loading, the control stays available.
    private var showsDeletedContentDisclosure: Bool {
        guard selectedFileIsDeleted else { return false }
        guard let diffFile else { return true }
        return !diffFile.binary && !diffFile.hunks.isEmpty
    }

    /// True while a native code renderer is mounted for the selected file.
    /// Collapsing deleted content must also stop its line reporting.
    private var codeContentVisible: Bool {
        guard file != nil, let diffFile, !diffFile.binary, !diffFile.hunks.isEmpty else { return false }
        guard store.currentDiffLoadError == nil else { return false }
        return !deletedContentIsHidden
    }

    private func headerSummary(_ file: PRReviewFile) -> String {
        let impact = file.impact?.rawValue ?? "unranked"
        guard selectedFileIsDeleted else { return "\(file.status) · \(impact)" }
        return "\(PRReviewDeletedFileDisclosure.summary(deletions: file.deletions)) · \(impact)"
    }

    private func deletedContentDisclosureButton(_ file: PRReviewFile) -> some View {
        let expanded = store.isDeletedContentExpanded(path: file.path)
        return Button(PRReviewDeletedFileDisclosure.actionLabel(expanded: expanded)) {
            store.setDeletedContentExpanded(!expanded, path: file.path)
        }
        .focusable()
        .help(expanded ? "Hide the removed lines for this deleted file" : "Show the removed lines for this deleted file")
        .accessibilityLabel(PRReviewDeletedFileDisclosure.actionLabel(expanded: expanded))
        .accessibilityValue(PRReviewDeletedFileDisclosure.stateDescription(expanded: expanded))
        .accessibilityHint("Toggles the removed lines for this deleted file")
        .accessibilityIdentifier(PRReviewDeletedFileDisclosure.accessibilityIdentifier)
        .disabled(!PRReviewDeletedFileDisclosure.canToggle(expanded: expanded, hasQuestionDraft: hasQuestionDraft))
    }

    private func diffText(_ diffFile: PRReviewDiffFile) -> some View {
        PRReviewDiffText(
            file: diffFile,
            baseSHA: currentDiff?.baseSHA ?? "",
            headSHA: currentDiff?.headSHA ?? "",
            highlight: highlight,
            scrollRequest: scrollRequest,
            askAI: askAI,
            questionDraftChanged: { isNonEmpty in
                hasQuestionDraft = isNonEmpty
                questionDraftChanged(isNonEmpty)
            },
            onVisibleLinesChange: { path, start, end, side in
                guard store.selectedPath == path else { return }
                if store.isDeletedFile(path: path),
                   !store.isDeletedContentExpanded(path: path) {
                    return
                }
                store.visibleLines = (path, start, end, side)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deletedContentHidden(_ file: PRReviewFile) -> some View {
        ContentUnavailableView {
            Label("Deleted content is hidden", systemImage: "eye.slash")
        } description: {
            Text(PRReviewDeletedFileDisclosure.hiddenDetail(deletions: file.deletions))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("pr-review-deleted-content-hidden")
    }

    private var scrollRequest: (path: String, line: Int, side: PRReviewSide, token: Int)? {
        guard let scrollRequest = store.scrollRequest, scrollRequest.path == store.selectedPath else { return nil }
        return scrollRequest
    }

    private func loadDiff() async {
        guard store.selectedReview != nil, store.selectedPath != nil else { return }
        await store.loadDiff(for: store.selectedPath)
    }

    private func openFullDiff() {
        if let url = (store.snapshot?.review ?? store.selectedReview).flatMap({ URL(string: $0.url + "/files") }) {
            openURL(url)
        }
    }

    private func unavailable(_ title: String, detail: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: retry ? "exclamationmark.triangle" : "doc.badge.ellipsis")
        } description: {
            Text(detail)
        } actions: {
            if retry {
                Button("Retry") { Task { await loadDiff() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
