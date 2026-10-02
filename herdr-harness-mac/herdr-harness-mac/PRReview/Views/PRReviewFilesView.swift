import AppKit
import SwiftUI

struct PRReviewFilesView: View {
    @Bindable var store: PRReviewStore
    @Bindable var comments = PRReviewCommentsSession()
    var canControl = false
    var questionHistory: PRReviewQuestionHistory?
    var openQuestion: (PRReviewQuestionHistory.Question) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var showGuideSource: (PRReviewGuideSource) -> Void = { _ in }
    var preferPrivateTranscription = true
    var questionDraftChanged: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            let comparisonInRail = geometry.size.height < 500 && (presentation == .content || presentation == .noFilterMatches)
            VStack(spacing: 0) {
            if store.supportsComparisons && !comparisonInRail { PRReviewComparisonControls(store: store) }
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
                    detail: store.supportsComparisons ? "These revisions have no changed files." : "This ready review did not report any changed files.",
                    systemImage: "doc"
                )
            case .content, .noFilterMatches:
                filesAndDiff(comparisonInRail: comparisonInRail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            Button("Undo Viewed Change") { Task { await store.undoViewed() } }
                .keyboardShortcut(PRReviewViewedHistoryShortcut.undoKey, modifiers: PRReviewViewedHistoryShortcut.undoModifiers)
                .disabled(!store.canUndoViewed)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
            Button("Redo Viewed Change") { Task { await store.redoViewed() } }
                .keyboardShortcut(PRReviewViewedHistoryShortcut.redoKey, modifiers: PRReviewViewedHistoryShortcut.redoModifiers)
                .disabled(!store.canRedoViewed)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
        }
        .task(id: store.comparisonLoadIdentity) { await store.loadComparison() }
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
            Task { await store.setViewedRecordingUndo(paths: [path], viewed: !file.viewed) }
            return .handled
        }
    }

    private func filesAndDiff(comparisonInRail: Bool) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                if store.supportsComparisons && comparisonInRail {
                    PRReviewComparisonControls(store: store, compact: true)
                }
                controls
                if presentation == .noFilterMatches {
                    if store.hideViewed && store.viewedProgress.isComplete {
                        ContentUnavailableView {
                            Label(PRReviewViewedProgress.allViewedTitle, systemImage: "checkmark.circle")
                        } description: {
                            Text(PRReviewViewedProgress.allViewedDetail)
                        } actions: {
                            Button(PRReviewViewedProgress.showViewedLabel) { store.hideViewed = false }
                                .herdrProminentButton()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .accessibilityIdentifier("pr-review-all-viewed")
                    } else {
                        ContentUnavailableView {
                            Label("No matching files", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Change the impact, viewed, or text filters.")
                        } actions: {
                            Button("Clear filters", action: clearFilters)
                                .herdrProminentButton()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .accessibilityIdentifier("pr-review-no-filter-matches")
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(store.orderedFiles.enumerated()), id: \.element.id) { index, file in
                                    PRReviewFileRow(file: file, index: index, selected: file.path == store.selectedPath,
                                                    guided: store.viewMode == .guided) {
                                        store.selectedPath = file.path
                                    } setViewed: { viewed in
                                        Task { await store.setViewedRecordingUndo(paths: [file.path], viewed: viewed) }
                                    }
                                    .id(file.path)
                                }
                            }
                            .padding(8)
                        }
                        .onAppear {
                            guard let path = store.selectedPath,
                                  store.orderedFiles.contains(where: { $0.path == path })
                            else { return }
                            proxy.scrollTo(path, anchor: .center)
                        }
                        .onChange(of: store.selectedPath) { _, path in
                            guard let path,
                                  store.orderedFiles.contains(where: { $0.path == path })
                            else { return }
                            withAnimation(.snappy) { proxy.scrollTo(path, anchor: .center) }
                        }
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
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        PRReviewDiffView(
                            store: store,
                            comments: comments,
                            compact: geometry.size.height < 500,
                            questionHistory: questionHistory,
                            openQuestion: openQuestion,
                            openURL: openURL,
                            askAI: askAI,
                            questionDraftChanged: questionDraftChanged
                        )
                        if store.guide.isExpanded && geometry.size.width >= 760 {
                            PRReviewGuideDetails(session: store.guide, showSource: showGuideSource)
                                .frame(width: 310)
                        }
                    }.frame(maxHeight: .infinity)
                    if store.guide.isExpanded && geometry.size.width < 760 {
                        PRReviewGuideDetails(session: store.guide, showSource: showGuideSource)
                            .frame(height: min(280, geometry.size.height * 0.42))
                    }
                    PRReviewGuideDock(session: store.guide, preferPrivateTranscription: preferPrivateTranscription, compact: geometry.size.height < 500)
                }
            }
            .frame(minWidth: PRReviewFilesLayout.minimumDiffWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let progress = store.viewedProgress
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.summary)
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(progress.isComplete ? HerdrTheme.text : HerdrTheme.mist)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(HerdrTheme.controlAccent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progress.accessibilityLabel)
            .accessibilityValue(progress.accessibilityValue)
            .accessibilityIdentifier("pr-review-viewed-progress")
            Picker("Order", selection: $store.viewMode) {
                Text("GitHub order").tag(PRReviewViewMode.github)
                Text("Suggested").tag(PRReviewViewMode.guided)
            }
            .pickerStyle(.segmented)
            .tint(HerdrTheme.controlAccent)
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
        store.normalizeSelectedFile()
    }

    private var presentation: PRReviewFilesPresentation {
        if store.isLoadingComparison && store.comparisonFiles.isEmpty { return .loading }
        return PRReviewFilesPresentation.resolve(
            status: store.snapshot?.review.status ?? store.selectedReview?.status,
            reviewError: store.snapshot?.review.error ?? store.selectedReview?.error,
            hasSnapshot: store.snapshot != nil,
            fileCount: store.comparisonFiles.count,
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
                    .herdrProminentButton()
            }
        }
        .accessibilityIdentifier("pr-review-files-state")
    }
}

enum PRReviewViewedHistoryShortcut {
    static let undoKey: KeyEquivalent = "z"
    static let undoModifiers: EventModifiers = .control
    static let redoKey: KeyEquivalent = "z"
    static let redoModifiers: EventModifiers = [.control, .shift]
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

/// Places the selected-file actions. One group right-aligns by itself; two
/// groups share a right-aligned row while both fit, and stack left-aligned
/// when enlarged text or a minimum-size pop-out would make them crowd.
///
/// A custom layout is used instead of `ViewThatFits` because a losing
/// `ViewThatFits` candidate can still mount duplicate controls in offscreen
/// render snapshots, which would double the header's buttons there.
struct PRReviewHeaderActionsLayout: Layout {
    var spacing: CGFloat = 8

    enum Arrangement: Equatable {
        case inline
        case stacked

        /// The row decision for group widths measured at their ideal size.
        static func resolve(groupWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat) -> Arrangement {
            let combined = groupWidths.reduce(0, +) + spacing * CGFloat(max(0, groupWidths.count - 1))
            return combined <= availableWidth ? .inline : .stacked
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map(\.width)
        let arrangement = Arrangement.resolve(
            groupWidths: widths,
            availableWidth: proposal.width ?? .greatestFiniteMagnitude,
            spacing: spacing
        )
        switch arrangement {
        case .inline:
            let combined = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
            return CGSize(width: proposal.width ?? combined, height: sizes.map(\.height).max() ?? 0)
        case .stacked:
            let stacked = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
            return CGSize(width: proposal.width ?? (widths.max() ?? 0), height: stacked)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let arrangement = Arrangement.resolve(
            groupWidths: sizes.map(\.width),
            availableWidth: bounds.width,
            spacing: spacing
        )
        switch arrangement {
        case .inline:
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                if index == subviews.count - 1 {
                    x = bounds.maxX - sizes[index].width
                }
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
        case .stacked:
            var y = bounds.minY
            for (index, subview) in subviews.enumerated() {
                let size = sizes[index]
                let width = min(bounds.width, size.width)
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                y += size.height + spacing
            }
        }
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
                    if file.viewed {
                        Label(PRReviewViewedProgress.viewedBadgeLabel, systemImage: "checkmark")
                            .herdrFont(.caption2, weight: .semibold)
                            .foregroundStyle(HerdrTheme.text)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(HerdrTheme.elevated, in: .capsule)
                            .fixedSize()
                            .accessibilityIdentifier("pr-review-file-viewed-\(index)")
                            .accessibilityHidden(true)
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
                .accessibilityLabel("Viewed")
                .accessibilityIdentifier("pr-review-viewed-\(index)")
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(selected ? HerdrTheme.selection : .clear, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .help(file.path)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityValue(PRReviewViewedProgress.rowAccessibilityValue(viewed: file.viewed))
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
    @Bindable var comments = PRReviewCommentsSession()
    var compact = false
    var questionHistory: PRReviewQuestionHistory?
    var openQuestion: (PRReviewQuestionHistory.Question) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }
    @State private var hasQuestionDraft = false
    @State private var showingImpactDetails = false

    private var file: PRReviewFile? { store.comparisonFiles.first { $0.path == store.selectedPath } }
    private var currentDiff: PRReviewDiff? { store.currentDiff }
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
                                         headSHA: store.snapshot?.review.headSHA ?? "", open: openQuestion, compact: compact)
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
                    HStack(spacing: 5) {
                        Text(headerSummary(file)).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                        if compact {
                            Button("Impact details", systemImage: "info.circle") { showingImpactDetails = true }
                                .labelStyle(.iconOnly).buttonStyle(.herdrPlain)
                                .popover(isPresented: $showingImpactDetails) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(file.impactExplanation)
                                        if let reason = file.guidedReason { Text(reason) }
                                    }
                                    .herdrFont(.caption).textSelection(.enabled)
                                    .frame(width: 320, alignment: .leading).padding(12)
                                }
                        }
                    }
                }
                Spacer()
            }
            if !compact {
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
            }
            PRReviewHeaderActionsLayout(spacing: 8) {
                if showsDeletedContentDisclosure {
                    deletedContentDisclosureButton(file)
                }
                HStack(spacing: 8) {
                    Button("Previous") { store.selectedPath = store.previousFile()?.path }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("Next") { store.selectedPath = store.nextFile()?.path }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    Button(file.viewed ? "Mark unviewed" : "Mark viewed") {
                        Task { await store.setViewedRecordingUndo(paths: [file.path], viewed: !file.viewed) }
                    }
                    .keyboardShortcut("v", modifiers: .option)
                    .help("Toggle viewed (⌥V). Undo with ⌃Z, redo with ⌃⇧Z.")
                    Button("GitHub", action: openFullDiff)
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(compact ? 8 : 10)
        .background(HerdrTheme.ink)
    }

    private var highlight: (start: Int, end: Int, side: PRReviewSide)? {
        guard let highlight = store.highlight, highlight.path == store.selectedPath else { return nil }
        return (highlight.start, highlight.end, highlight.side)
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
            baseSHA: currentDiff?.comparison?.beforeSHA ?? currentDiff?.baseSHA ?? "",
            headSHA: currentDiff?.comparison?.afterSHA ?? currentDiff?.headSHA ?? "",
            diffStyle: store.diffStyle,
            overflow: store.diffOverflow,
            comparison: currentDiff?.comparison,
            comparisonSelection: store.supportsComparisons ? store.comparisonSelection : nil,
            guideAnnotations: store.guide.annotations,
            highlight: highlight,
            scrollRequest: scrollRequest,
            askAI: { selection, view, rect in
                guard selection.comparison == currentDiff?.comparison,
                      selection.comparisonSelection == (store.supportsComparisons ? store.comparisonSelection : nil) else { return }
                askAI(selection, view, rect)
            },
            addComment: addComment,
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

    /// The bundled renderer only offers Add comment while a store is attached
    /// and the host can accept a selection, so existing ask-only call sites
    /// keep their exact behavior.
    private var addComment: ((PRReviewSelection) -> Void)? {
        guard comments.isReady, store.comparisonSelection == .all else { return nil }
        return { selection in
            comments.beginComposition(selection: selection, store: store)
        }
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
                    .herdrProminentButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
