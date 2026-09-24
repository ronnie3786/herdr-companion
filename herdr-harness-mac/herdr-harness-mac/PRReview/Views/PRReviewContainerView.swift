import AppKit
import SwiftUI

struct PRReviewContainerView: View {
    @Bindable var store: PRReviewStore
    @Bindable var comments: PRReviewCommentsSession
    var canControl = false
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }
    var setCreating: (Bool) -> Void = { _ in }
    var openPane: (String, String?) -> Void = { _, _ in }
    var setAddingSkill: (Bool) -> Void = { _ in }
    var popOut: ((PRReviewWindowTarget) -> Void)?
    var navigationTitle = "PR Review"
    /// The live model, when the container runs inside the app, so an opened
    /// document window can observe credential and machine changes on its own.
    var documentHost: HerdrAppModel? = nil

    init(store: PRReviewStore, comments: PRReviewCommentsSession = PRReviewCommentsSession(), canControl: Bool = false, openURL: @escaping (URL) -> Void = { _ in }, askAI: @escaping (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }, questionDraftChanged: @escaping (Bool) -> Void = { _ in }, setCreating: @escaping (Bool) -> Void = { _ in }, openPane: @escaping (String, String?) -> Void = { _, _ in }, setAddingSkill: @escaping (Bool) -> Void = { _ in }, popOut: ((PRReviewWindowTarget) -> Void)? = nil, navigationTitle: String = "PR Review", documentHost: HerdrAppModel? = nil) {
        _store = Bindable(store)
        _comments = Bindable(comments)
        self.canControl = canControl
        self.openURL = openURL
        self.askAI = askAI
        self.questionDraftChanged = questionDraftChanged
        self.setCreating = setCreating
        self.openPane = openPane
        self.setAddingSkill = setAddingSkill
        self.popOut = popOut
        self.navigationTitle = navigationTitle
        self.documentHost = documentHost
    }

    var body: some View {
        ZStack {
            HerdrBackground()
            VStack(spacing: 0) {
                if let review = store.snapshot?.review ?? store.selectedReview {
                    header(review)
                    Rectangle().fill(HerdrTheme.separator).frame(height: 1)
                    Picker("View", selection: $store.tab) {
                        Text("Files").tag(PRReviewTab.files)
                        Text("Context (\(review.documentCount))").tag(PRReviewTab.context)
                        Text("Agents (\(review.runningRuns) running)").tag(PRReviewTab.agents)
                        Text("Skills").tag(PRReviewTab.skills)
                    }
                    .pickerStyle(.segmented)
                    .tint(HerdrTheme.controlAccent)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pr-review-mode-picker")
                    content(review)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                } else if store.unconfigured || store.unsupported {
                    ContentUnavailableView(store.error ?? "PR Review is unavailable", systemImage: "arrow.triangle.pull")
                        .accessibilityIdentifier("pr-review-unavailable")
                } else if !store.hasLoaded || store.isRefreshing {
                    ContentUnavailableView("Loading PR reviews", systemImage: "arrow.triangle.2.circlepath")
                        .accessibilityIdentifier("pr-review-loading")
                } else if let error = store.error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("pr-review-error")
                } else {
                    ContentUnavailableView("Choose a PR review", systemImage: "arrow.triangle.pull")
                        .accessibilityIdentifier("pr-review-empty")
                }
            }
            .sheet(isPresented: commentsSheetPresented, onDismiss: { comments.dismissCommentsSheet() }) {
                commentSheet
            }
        }
        .navigationTitle(navigationTitle)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-container")
        .onAppear {
            comments.updateScope(from: store)
            comments.configure(openURL: openURL)
        }
        .onChange(of: store.currentMachineID) { _, _ in comments.updateScope(from: store) }
        .onChange(of: store.selectedReviewID) { _, _ in comments.updateScope(from: store) }
        .sheet(isPresented: $store.isPresentingStartSheet, onDismiss: { setCreating(false) }) {
            PRReviewStartSheet(store: store) {
                store.pendingURL = nil
                store.isPresentingStartSheet = false
                setCreating(false)
            }
        }
    }

    private func header(_ review: PRReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(PRReviewHeaderText.title(for: review))
                    .herdrFont(size: 20, weight: .semibold, relativeTo: .title2)
                    .lineLimit(1)
                Spacer()
                commentsButton(review)
                Button(store.isRefreshingReview ? "Refreshing…" : "Refresh") {
                    Task { await store.refreshReview() }
                }.disabled(!canControl || store.isRefreshingReview)
                Button(review.archivedAt == nil ? "Archive" : "Unarchive") {
                    Task { await store.archive(review.archivedAt == nil) }
                }.disabled(!canControl)
            }
            HStack(spacing: 10) {
                Button(PRReviewHeaderText.label(for: review)) {
                    if let url = URL(string: review.url) { openURL(url) }
                }.buttonStyle(.link)
                if !review.headRef.isEmpty, !review.baseRef.isEmpty {
                    Text("\(review.headRef) → \(review.baseRef)")
                }
                Text("+\(review.additions) −\(review.deletions) · \(review.changedFiles) files")
                if !review.author.isEmpty { Text("by \(review.author)") }
                Text(review.status.rawValue.capitalized).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(HerdrTheme.elevated, in: .capsule)
                rankingChip(review)
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            if let error = store.error ?? review.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            if let popOut, review.archivedAt == nil, let machineID = store.currentMachineID {
                let target = PRReviewWindowTarget(machineID: machineID, reviewID: review.id)
                Button("Pop Out into Window") { popOut(target) }
                    .accessibilityIdentifier(target.popOutActionAccessibilityIdentifier)
            }
        }
    }

    private func rankingChip(_ review: PRReviewSummary) -> some View {
        Group {
            if review.rankingState == .running { Text("Ranking…") }
            else if review.rankingState == .done { Text("Ranked") }
            else { Button("Rank files") { Task { await store.rank() } }.disabled(!canControl) }
        }
    }

    /// Review-wide saved comments are available from every tab, including
    /// empty and filtered file states and archived reviews. The count is
    /// scoped to this configured machine and review id, never to a label.
    private func commentsButton(_ review: PRReviewSummary) -> some View {
        let count = comments.count(machineID: store.currentMachineID, reviewID: review.id)
        return Button {
            comments.presentList(machineID: store.currentMachineID, reviewID: review.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Comments")
                if count > 0 {
                    Text("\(count)")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HerdrTheme.selection, in: .capsule)
                }
            }
        }
        .disabled(!comments.isReady)
        .help("Saved comments for this review")
        .accessibilityIdentifier("pr-review-comments-button")
        .accessibilityValue("\(count) saved")
    }

    private var commentsSheetPresented: Binding<Bool> {
        Binding(
            get: { comments.isPresentingComments },
            set: { presented in
                if !presented { comments.dismissCommentsSheet() }
            }
        )
    }

    @ViewBuilder
    private var commentSheet: some View {
        Group {
            if comments.composition != nil {
                PRReviewCommentEditor(session: comments)
            } else {
                PRReviewCommentsView(
                    session: comments,
                    review: store.snapshot?.review ?? store.selectedReview,
                    currentFilePaths: store.snapshot.map { Set($0.files.map(\.path)) },
                    edit: { comments.beginEditing($0) },
                    showInDiff: { comment in
                        Task { await comments.showInDiff(comment, store: store) }
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .interactiveDismissDisabled(comments.hasDirtyDraft || comments.isSaving)
    }

    @ViewBuilder private func content(_ review: PRReviewSummary) -> some View {
        switch store.tab {
        case .files:
            PRReviewFilesView(
                store: store,
                comments: comments,
                canControl: canControl,
                questionHistory: documentHost?.prReviewQuestions,
                openQuestion: { documentHost?.presentSavedPRReviewQuestion($0) },
                openURL: openURL,
                askAI: askAI,
                questionDraftChanged: questionDraftChanged
            )
        case .context:
            PRReviewContextView(store: store, documentHost: documentHost)
        case .agents:
            PRReviewAgentsView(store: store, openPane: openPane)
        case .skills:
            PRReviewSkillsView(store: store, setAddingSkill: setAddingSkill)
        }
    }

}

enum PRReviewHeaderText {
    static func title(for review: PRReviewSummary) -> String {
        let title = review.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? label(for: review) : title
    }

    static func label(for review: PRReviewSummary) -> String {
        let repository = [review.owner, review.repo].filter { !$0.isEmpty }.joined(separator: "/")
        if !repository.isEmpty, review.number > 0 { return "\(repository) #\(review.number)" }
        if review.number > 0 { return "Pull request #\(review.number)" }
        if !repository.isEmpty { return repository }
        return "Pull request review"
    }
}
