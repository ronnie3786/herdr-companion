import AppKit
import SwiftUI

struct PRReviewFilesView: View {
    @Bindable var store: PRReviewStore
    var canControl = false
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
                maxHeight: .infinity
            )
            PRReviewDiffView(
                store: store,
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
        if status == .preparing { return .preparing }
        if status == .failed { return .failed(reviewError ?? "The companion could not prepare this review.") }
        if !hasSnapshot { return .loading }
        if fileCount == 0 { return .noFiles }
        if visibleFileCount == 0 { return .noFilterMatches }
        return .content
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
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .herdrFont(.subheadline, weight: .semibold).lineLimit(1)
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
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }

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
                        PRReviewDiffText(
                            file: diffFile,
                            baseSHA: currentDiff?.baseSHA ?? "",
                            headSHA: currentDiff?.headSHA ?? "",
                            highlight: highlight,
                            scrollRequest: scrollRequest,
                            askAI: askAI,
                            questionDraftChanged: questionDraftChanged,
                            onVisibleLinesChange: { path, start, end, side in
                                store.visibleLines = (path, start, end, side)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: store.currentDiffRequestIdentity) { await loadDiff() }
        .onChange(of: store.scrollRequest?.token) { _, _ in
            guard let request = store.scrollRequest else { return }
            store.selectedPath = request.path
        }
    }

    private var partialDiffWarning: some View {
        HStack(spacing: 8) {
            Label("Partial diff. Available code is shown below.", systemImage: "exclamationmark.triangle")
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

    private func header(_ file: PRReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path).herdrFont(.headline).lineLimit(1)
                    Text("\(file.status) · \(file.impact?.rawValue ?? "unranked")").herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
            }
            if store.viewMode == .guided, let order = file.guidedOrder {
                Text("Guided order #\(order) · \(file.guidedReason ?? "Review this file next")")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
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
    }
}
