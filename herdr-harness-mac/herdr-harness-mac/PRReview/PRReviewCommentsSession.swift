import AppKit
import Foundation
import Observation

/// The machine/review pair whose saved comments a session presents.
///
/// Identity is the configured machine and the server-local review id, never a
/// display name or pull request number. Two hosts that reuse a review id keep
/// separate records.
struct PRReviewCommentScope: Equatable, Sendable {
    var machineID: String
    var reviewID: String
}

/// How a saved comment's frozen anchor relates to the revision now loaded.
enum PRReviewCommentLocationStatus: Equatable, Sendable {
    /// The loaded review still carries the comment's recorded revision.
    case current
    /// The review's base/head moved since the comment was saved. The saved
    /// excerpt remains readable, but it is never mapped onto current lines.
    case earlierRevision
    /// The current revision no longer lists the file the comment was saved on.
    case missingFromCurrentRevision
}

/// The result of asking to reveal a saved comment in the current diff.
enum PRReviewCommentNavigationOutcome: Equatable, Sendable {
    case shown
    case earlierRevision
    case notInDiff(PRReviewCommentAnchorProblem?)
    case missingScope
}

/// Everything one local editor needs, frozen when composition opens.
///
/// The origin (machine, review, canonical PR URL, and the exact revision diff
/// the anchor was validated against) does not follow later refreshes or
/// navigation. A draft is therefore always attached to the origin it was
/// started from.
struct PRReviewCommentComposition: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case new
        case edit(commentID: UUID, expectedVersion: Int)
    }

    /// Where the editor was opened from, which decides what Save/Cancel
    /// returns to.
    enum Source: Equatable, Sendable {
        case selection
        case commentList
    }

    var id: UUID
    var kind: Kind
    var source: Source
    var machineID: String
    var reviewID: String
    var reviewLabel: String
    var prURL: String
    var anchor: PRReviewCommentAnchor
    /// The revision diff a new anchor is validated against. Nil while editing
    /// an existing comment, whose body-only edit needs no anchor validation.
    var diff: PRReviewDiff?
    var originalBody: String

    var isNew: Bool { kind == .new }
}

/// Presentation state for local PR Review comments.
///
/// One session owns the comment sheet for one review window: the main window's
/// session lives with the shell, and each popped-out review window owns its
/// own. All sessions share one `PRReviewCommentStore`, so records saved in any
/// window appear everywhere without sharing a sheet or a draft.
@MainActor
@Observable
final class PRReviewCommentsSession {
    private(set) var store: PRReviewCommentStore?
    private(set) var scope: PRReviewCommentScope?
    private(set) var composition: PRReviewCommentComposition?
    var draftBody = ""
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var isConfirmingDiscard = false
    /// Explains a refused Show in diff request without inventing a highlight.
    private(set) var navigationMessage: String?
    private(set) var isPresentingList = false

    @ObservationIgnored var copyText: @MainActor (String) -> Void
    @ObservationIgnored var openURL: (URL) -> Void

    init(
        store: PRReviewCommentStore? = nil,
        copyText: @escaping @MainActor (String) -> Void = { PRReviewCommentsSession.writeToPasteboard($0) },
        openURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.store = store
        self.copyText = copyText
        self.openURL = openURL
    }

    // MARK: - Store and scope

    /// The store is process-owned in `HerdrAppModel`; the main window's shell
    /// attaches it once the app model exists.
    func attach(store: PRReviewCommentStore) {
        self.store = store
    }

    /// Wires the presenting window's browser opener into the manual handoff.
    /// Tests and previews keep the initial boundary so they can capture URLs.
    func configure(openURL: @escaping (URL) -> Void) {
        self.openURL = openURL
    }

    var isReady: Bool { store != nil }

    func updateScope(machineID: String?, reviewID: String?) {
        guard let machineID, let reviewID,
              !machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reviewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            scope = nil
            return
        }
        scope = PRReviewCommentScope(machineID: machineID, reviewID: reviewID)
    }

    func updateScope(from store: PRReviewStore) {
        updateScope(machineID: store.currentMachineID, reviewID: store.selectedReviewID)
    }

    // MARK: - Listing

    /// Saved records for the current scope, ordered by file, then first saved
    /// line, then creation time so the list is stable across refreshes.
    var visibleComments: [PRReviewComment] {
        guard let store, let scope else { return [] }
        return store.comments(machineID: scope.machineID, reviewID: scope.reviewID)
            .sorted { first, second in
                if first.anchor.path != second.anchor.path {
                    return first.anchor.path < second.anchor.path
                }
                let firstLine = first.anchor.spans.first?.start ?? 0
                let secondLine = second.anchor.spans.first?.start ?? 0
                if firstLine != secondLine { return firstLine < secondLine }
                if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
                return first.id.uuidString < second.id.uuidString
            }
    }

    func count(machineID: String?, reviewID: String?) -> Int {
        guard let store, let machineID, let reviewID else { return 0 }
        return store.comments(machineID: machineID, reviewID: reviewID).count
    }

    func locationStatus(
        for comment: PRReviewComment,
        review: PRReviewSummary?,
        currentFilePaths: Set<String>?
    ) -> PRReviewCommentLocationStatus {
        if let review,
           !review.baseSHA.isEmpty,
           !review.headSHA.isEmpty,
           (comment.anchor.baseSHA.caseInsensitiveCompare(review.baseSHA) != .orderedSame
            || comment.anchor.headSHA.caseInsensitiveCompare(review.headSHA) != .orderedSame) {
            return .earlierRevision
        }
        if let currentFilePaths, !currentFilePaths.contains(comment.anchor.path) {
            return .missingFromCurrentRevision
        }
        return .current
    }

    // MARK: - Presentation

    var isPresentingComments: Bool {
        isPresentingList || composition != nil
    }

    var hasDirtyDraft: Bool {
        guard let composition else { return false }
        return draftBody != composition.originalBody
    }

    var canSave: Bool {
        composition != nil
            && !isSaving
            && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func presentList(machineID: String?, reviewID: String?) {
        updateScope(machineID: machineID, reviewID: reviewID)
        guard scope != nil else { return }
        if composition == nil {
            draftBody = ""
            saveError = nil
        }
        navigationMessage = nil
        isPresentingList = true
    }

    /// Closing the whole sheet (Done, Escape on a clean list, or a completed
    /// Save) clears every transient editor value.
    func dismissCommentsSheet() {
        isPresentingList = false
        composition = nil
        draftBody = ""
        saveError = nil
        isConfirmingDiscard = false
        navigationMessage = nil
    }

    // MARK: - Composition

    /// Opens the multiline editor for a code selection.
    ///
    /// The loaded diff, revision, machine, review, and PR URL are captured at
    /// this moment. A later refresh cannot retarget or invalidate the draft,
    /// and the anchor is validated before the editor is offered.
    @discardableResult
    func beginComposition(selection: PRReviewSelection, store: PRReviewStore) -> Bool {
        // A dirty editor is never silently replaced or retargeted.
        guard composition == nil else { return false }
        guard self.store != nil,
              let machineID = store.currentMachineID,
              let reviewID = store.selectedReviewID,
              let review = store.snapshot?.review ?? store.selectedReview,
              let diff = store.diff,
              diff.reviewID.isEmpty || diff.reviewID == reviewID,
              review.baseSHA.isEmpty || diff.baseSHA == review.baseSHA,
              review.headSHA.isEmpty || diff.headSHA == review.headSHA
        else { return false }

        let spans = selection.spans.map {
            PRReviewCommentSpan(side: $0.side, start: $0.start, end: $0.end)
        }
        let anchor = PRReviewCommentAnchor(
            baseSHA: diff.baseSHA,
            headSHA: diff.headSHA,
            mergeBaseSHA: review.mergeBaseSHA,
            path: selection.path,
            oldPath: selection.oldPath,
            spans: spans,
            code: selection.text
        )
        guard anchor.problem(against: diff) == nil else { return false }

        composition = PRReviewCommentComposition(
            id: UUID(),
            kind: .new,
            source: .selection,
            machineID: machineID,
            reviewID: reviewID,
            reviewLabel: PRReviewHeaderText.title(for: review),
            prURL: Self.storageURLString(for: review, demo: store.isDemo),
            anchor: anchor,
            diff: diff,
            originalBody: ""
        )
        draftBody = ""
        saveError = nil
        isConfirmingDiscard = false
        navigationMessage = nil
        isPresentingList = false
        return true
    }

    func beginEditing(_ comment: PRReviewComment) {
        // A dirty editor is never silently replaced or retargeted.
        guard composition == nil, let store else { return }
        let current = store.comment(id: comment.id) ?? comment
        composition = PRReviewCommentComposition(
            id: UUID(),
            kind: .edit(commentID: current.id, expectedVersion: current.editVersion),
            source: .commentList,
            machineID: current.machineID,
            reviewID: current.reviewID,
            reviewLabel: "",
            prURL: current.prURL,
            anchor: current.anchor,
            diff: nil,
            originalBody: current.body
        )
        draftBody = current.body
        saveError = nil
        isConfirmingDiscard = false
        navigationMessage = nil
    }

    func cancelComposition() {
        guard composition != nil else { return }
        if hasDirtyDraft {
            isConfirmingDiscard = true
        } else {
            discardComposition()
        }
    }

    func confirmDiscard() {
        isConfirmingDiscard = false
        discardComposition()
    }

    func keepEditing() {
        isConfirmingDiscard = false
    }

    /// Persists the draft against the frozen origin.
    ///
    /// The draft text is never trimmed or rewritten. A failure keeps the text
    /// in the editor, records the reason, and reports no success.
    func save() {
        guard let composition, let store, !isSaving else { return }
        guard !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = PRReviewCommentStoreError.blankBody.errorDescription
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            switch composition.kind {
            case .new:
                guard let diff = composition.diff else {
                    saveError = PRReviewCommentStoreError.invalidAnchor(.revisionMismatch).errorDescription
                    return
                }
                let draft = PRReviewCommentDraft(
                    machineID: composition.machineID,
                    reviewID: composition.reviewID,
                    prURL: composition.prURL,
                    anchor: composition.anchor,
                    body: draftBody
                )
                _ = try store.insert(draft, diff: diff)
            case let .edit(commentID, expectedVersion):
                _ = try store.edit(id: commentID, body: draftBody, expecting: expectedVersion)
            }
            finishSavedComposition()
        } catch let error as PRReviewCommentStoreError {
            saveError = error.errorDescription
        } catch {
            saveError = PRReviewCommentStoreError.writeFailed.errorDescription
        }
    }

    private func discardComposition() {
        composition = nil
        draftBody = ""
        saveError = nil
        isConfirmingDiscard = false
    }

    private func finishSavedComposition() {
        let returnsToList = composition?.source == .commentList
        composition = nil
        draftBody = ""
        saveError = nil
        isConfirmingDiscard = false
        navigationMessage = nil
        if !returnsToList { isPresentingList = false }
    }

    // MARK: - Manual publishing handoff

    /// Copies the saved Markdown exactly. Nothing is submitted anywhere.
    func copy(_ comment: PRReviewComment) {
        copyText(comment.body)
    }

    /// Opens the pull request's specific file in the diff, never the review
    /// overview or the repository file browser.
    func openFileInGitHub(_ comment: PRReviewComment) {
        guard let url = PRReviewCommentLinks.filesURL(for: comment) else { return }
        openURL(url)
    }

    /// Opens the retained original-revision source when a valid anchor exists.
    func openOriginalRevision(_ comment: PRReviewComment, span: PRReviewCommentSpan? = nil) {
        let resolvedSpan = span ?? comment.anchor.spans.first
        guard let side = resolvedSpan?.side,
              let url = PRReviewCommentLinks.originalRevisionBlobURL(
                  for: comment,
                  side: side,
                  span: resolvedSpan
              )
        else { return }
        openURL(url)
    }

    // MARK: - Reveal in diff

    /// Reveals a saved comment's exact same-revision location.
    ///
    /// The revision is verified before any presentation state changes: an
    /// earlier-revision or missing location keeps the saved excerpt and never
    /// highlights guessed current lines. On success the file is unfiltered,
    /// Files becomes the active tab, and the first saved span is highlighted
    /// and scrolled to.
    func showInDiff(_ comment: PRReviewComment, store: PRReviewStore) async {
        switch await navigationOutcome(for: comment, store: store) {
        case .shown:
            navigationMessage = nil
            dismissCommentsSheet()
        case .earlierRevision:
            navigationMessage = "This comment was saved against an earlier revision. Its saved code stays available here, and no current lines are highlighted."
        case let .notInDiff(problem):
            navigationMessage = Self.navigationFailureMessage(for: problem)
        case .missingScope:
            navigationMessage = "This comment belongs to a different review, so it cannot be shown in the open diff."
        }
    }

    private func navigationOutcome(
        for comment: PRReviewComment,
        store: PRReviewStore
    ) async -> PRReviewCommentNavigationOutcome {
        guard comment.machineID == store.currentMachineID,
              comment.reviewID == store.selectedReviewID
        else { return .missingScope }
        guard let review = store.snapshot?.review ?? store.selectedReview else { return .missingScope }
        if locationStatus(for: comment, review: review, currentFilePaths: nil) == .earlierRevision {
            return .earlierRevision
        }
        if let snapshot = store.snapshot,
           !snapshot.files.contains(where: { $0.path == comment.anchor.path }) {
            // The current revision no longer lists the file. Its saved excerpt
            // stays in the list; no guessed replacement is highlighted.
            return .notInDiff(.missingFile)
        }

        // Clear the filters that could hide the file, then select Files and
        // the saved path. The diff view's own task loads the file when this
        // path is not the loaded one.
        store.tab = .files
        store.impactFilter = .all
        store.hideViewed = false
        store.search = ""
        store.selectedPath = comment.anchor.path

        let loaded = isLoadedDiffCurrent(store.diff, path: comment.anchor.path, review: review)
        if !loaded {
            await store.loadDiff(for: comment.anchor.path)
        }

        guard let diff = store.diff,
              diff.files.contains(where: { $0.path == comment.anchor.path })
        else { return .notInDiff(nil) }
        if let problem = comment.anchor.problem(against: diff) {
            return .notInDiff(problem)
        }
        guard let span = comment.anchor.spans.first else { return .notInDiff(.emptySpans) }

        store.highlight = (comment.anchor.path, span.start, span.end, span.side)
        store.scroll(to: comment.anchor.path, line: span.start, side: span.side)
        return .shown
    }

    // MARK: - Helpers

    private func isLoadedDiffCurrent(
        _ diff: PRReviewDiff?,
        path: String,
        review: PRReviewSummary
    ) -> Bool {
        guard let diff, diff.files.contains(where: { $0.path == path }) else { return false }
        guard review.baseSHA.isEmpty || diff.baseSHA == review.baseSHA else { return false }
        guard review.headSHA.isEmpty || diff.headSHA == review.headSHA else { return false }
        return true
    }

    /// The demo fleet points at a synthetic companion origin, while saved
    /// comments and their GitHub links require a canonical pull request URL.
    /// Demo compositions therefore freeze a synthetic `github.com` URL built
    /// from the same owner/repo/number; real reviews always keep their own
    /// canonicalized URL.
    static func storageURLString(for review: PRReviewSummary, demo: Bool) -> String {
        if PRReviewCommentLinks.reference(from: review.url) != nil { return review.url }
        guard demo,
              review.number > 0,
              !review.owner.isEmpty,
              !review.repo.isEmpty,
              let synthetic = URL(string: "https://github.com/\(review.owner)/\(review.repo)/pull/\(review.number)"),
              PRReviewCommentLinks.reference(from: synthetic.absoluteString) != nil
        else { return review.url }
        return synthetic.absoluteString
    }

    static func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func navigationFailureMessage(for problem: PRReviewCommentAnchorProblem?) -> String {
        guard let problem else {
            return "This file is not part of the loaded diff. The saved excerpt stays available here."
        }
        switch problem {
        case .binaryFile:
            return "This file is binary in the current revision, so there is no native text diff to show. The saved excerpt stays available here."
        case .partialDiff:
            return "Only a partial diff is available for this file, so the saved lines cannot be verified. The saved excerpt stays available here."
        case .lineNotFound:
            return "The saved lines are not part of the loaded diff. The saved excerpt stays available here; no current lines are highlighted."
        case .missingFile:
            return "This file is not part of the loaded diff. The saved excerpt stays available here."
        case .emptyPath, .emptyCode, .emptySpans, .revisionMismatch, .oldPathMismatch, .invalidSpan:
            return "The saved location no longer matches the loaded revision. The saved excerpt stays available here."
        }
    }
}

/// Human-readable labels shared by the comment list and editor.
enum PRReviewCommentText {
    static func locationLabel(for anchor: PRReviewCommentAnchor) -> String {
        anchor.spans.map { span in
            let side = span.side == .before ? "before" : "after"
            if span.start == span.end { return "\(side) line \(span.start)" }
            return "\(side) lines \(span.start)–\(span.end)"
        }
        .joined(separator: ", ")
    }

    static func revisionLabel(for anchor: PRReviewCommentAnchor) -> String {
        let head = anchor.headSHA.prefix(8)
        return head.isEmpty ? "saved revision" : "saved at \(head)"
    }
}
