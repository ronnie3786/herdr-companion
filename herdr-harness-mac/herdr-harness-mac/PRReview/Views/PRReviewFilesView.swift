import AppKit
import SwiftUI

struct PRReviewFilesView: View {
    @Bindable var store: PRReviewStore
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                controls
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
            .frame(minWidth: 240, idealWidth: 320)
            PRReviewDiffView(
                store: store,
                openURL: openURL,
                askAI: askAI,
                questionDraftChanged: questionDraftChanged
            )
                .frame(minWidth: 440)
        }
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Order", selection: $store.viewMode) {
                Text("GitHub order").tag(PRReviewViewMode.github)
                Text("Guided").tag(PRReviewViewMode.guided)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pr-review-view-mode")
            HStack(spacing: 4) {
                ForEach(PRReviewImpactFilter.allCases, id: \.self) { impact in
                    Button(impact.rawValue.capitalized) { store.impactFilter = impact }
                        .buttonStyle(.bordered)
                        .tint(store.impactFilter == impact ? HerdrTheme.controlAccent : HerdrTheme.surface)
                        .accessibilityIdentifier("pr-review-filter-\(impact.rawValue)")
                }
            }
            Toggle("Hide viewed", isOn: $store.hideViewed).herdrFont(.caption)
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
    private var diffFile: PRReviewDiffFile? { store.diff?.files.first { $0.path == store.selectedPath } }

    var body: some View {
        VStack(spacing: 0) {
            if let file {
                header(file)
                if file.status == "deleted" || diffFile?.binary == true || diffFile?.truncated == true {
                    ContentUnavailableView("Diff unavailable", systemImage: "doc.badge.ellipsis")
                } else if let diffFile {
                    PRReviewDiffText(
                        file: diffFile,
                        headSHA: store.diff?.headSHA ?? "",
                        highlight: highlight,
                        scrollRequest: scrollRequest,
                        askAI: askAI,
                        questionDraftChanged: questionDraftChanged,
                        onVisibleLinesChange: { path, start, end, side in
                            store.visibleLines = (path, start, end, side)
                        }
                    )
                } else {
                    ContentUnavailableView("Loading diff", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                ContentUnavailableView("Select a changed file", systemImage: "doc")
            }
        }
        .task(id: store.selectedPath) { await loadDiff() }
        .onChange(of: store.scrollRequest?.token) { _, _ in
            guard let request = store.scrollRequest else { return }
            store.selectedPath = request.path
        }
    }

    private func header(_ file: PRReviewFile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path).herdrFont(.headline).lineLimit(1)
                Text("\(file.status) · \(file.impact?.rawValue ?? "unranked")").herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                if store.viewMode == .guided, let order = file.guidedOrder {
                    Text("Guided order #\(order) - \(file.guidedReason ?? "Review this file next")").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                }
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
            Button("Open on GitHub") {
                if let url = store.selectedReview.flatMap({ URL(string: $0.url + "/files") }) { openURL(url) }
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
}
