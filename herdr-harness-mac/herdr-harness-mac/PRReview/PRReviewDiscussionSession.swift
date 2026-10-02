import Foundation
import Observation

@MainActor
@Observable
final class PRReviewDiscussionSession {
    struct Scope: Equatable, Hashable {
        var machineID: String
        var reviewID: String
        var generation: Int
    }

    struct Draft {
        var scope: Scope
        var threadID: String?
        var anchor: PRReviewDiscussionCreate.Anchor?
        var excerpt: String
        var requestID = UUID().uuidString
        var submittedBody: String?
    }

    private(set) var scope: Scope?
    private(set) var threads: [PRReviewDiscussion] = []
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isAvailable = false
    private(set) var draft: Draft?
    var draftBody = ""
    var isPresented = false
    var selectedThreadID: String?
    var filter = "open"
    @ObservationIgnored private var client: (any PRReviewDiscussionClient)?
    @ObservationIgnored private var loadGeneration = 0

    var openCount: Int { threads.filter { !$0.isResolved }.count }
    var canSave: Bool {
        isAvailable && !isSaving && draft?.scope == scope && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasDraft: Bool { draft != nil }
    var visibleThreads: [PRReviewDiscussion] {
        threads.filter { filter == "all" || $0.state == filter }
    }

    func configure(store: PRReviewStore) {
        let next = store.currentMachineID.flatMap { machine in
            store.selectedReviewID.map { Scope(machineID: machine, reviewID: $0, generation: store.guideConnectionGeneration) }
        }
        configure(scope: next, client: store.discussionClient,
                  available: store.isDemo || store.capabilities?.capabilities.contains("pr-review-comments-v1") == true)
    }

    func configure(scope next: Scope?, client: (any PRReviewDiscussionClient)?, available: Bool) {
        if next != scope {
            loadGeneration &+= 1
            threads = []
            selectedThreadID = nil
            error = nil
            isLoading = false
        }
        scope = next
        self.client = client
        isAvailable = available && next != nil && client != nil
    }

    func refresh() async {
        guard isAvailable, let client, let scope else { return }
        loadGeneration &+= 1
        let token = loadGeneration
        isLoading = true
        defer { if token == loadGeneration { isLoading = false } }
        do {
            let received = try await client.prReviewDiscussions(reviewID: scope.reviewID)
            guard token == loadGeneration, self.scope == scope, !Task.isCancelled else { return }
            threads = received
            if !isSaving && draft == nil { error = nil }
        } catch {
            guard token == loadGeneration, self.scope == scope, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func present(threadID: String? = nil) {
        selectedThreadID = threadID
        if let threadID, let thread = threads.first(where: { $0.id == threadID }), filter != "all", filter != thread.state {
            filter = "all"
        }
        isPresented = true
    }

    func beginComment(selection: PRReviewSelection? = nil, store: PRReviewStore) {
        guard draft == nil, isAvailable, let scope,
              scope.machineID == store.currentMachineID, scope.reviewID == store.selectedReviewID else { return }
        var anchor: PRReviewDiscussionCreate.Anchor?
        if let selection {
            guard let diff = store.currentDiff,
                  let review = store.snapshot?.review ?? store.selectedReview,
                  diff.baseSHA == review.baseSHA, diff.headSHA == review.headSHA,
                  selection.comparison == diff.comparison,
                  !selection.spans.isEmpty,
                  diff.files.contains(where: { $0.path == selection.path && !$0.binary }) else { return }
            anchor = .init(path: selection.path, baseSHA: review.baseSHA, headSHA: review.headSHA,
                           spans: selection.spans.map { .init(side: $0.side, start: $0.start, end: $0.end) },
                           comparison: store.comparisonSelection)
        }
        draft = Draft(scope: scope, anchor: anchor, excerpt: selection?.text ?? "")
        draftBody = ""
        error = nil
        isPresented = true
    }

    func beginReply(to thread: PRReviewDiscussion) {
        guard draft == nil, isAvailable, let scope, threads.contains(where: { $0.id == thread.id }) else { return }
        selectedThreadID = thread.id
        draft = Draft(scope: scope, threadID: thread.id, excerpt: "")
        draftBody = ""
        error = nil
        isPresented = true
    }

    func discardDraft() {
        guard !isSaving else { return }
        draft = nil
        draftBody = ""
        error = nil
    }

    func save() async {
        guard canSave, let client, var draft, let scope else { return }
        let body = draftBody
        if let submittedBody = draft.submittedBody, submittedBody != body { draft.requestID = UUID().uuidString }
        draft.submittedBody = body
        self.draft = draft
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved: PRReviewDiscussion
            if let threadID = draft.threadID {
                saved = try await client.replyToPRReviewDiscussion(reviewID: scope.reviewID, threadID: threadID,
                    request: .init(body: body, requestID: draft.requestID))
            } else {
                saved = try await client.createPRReviewDiscussion(reviewID: scope.reviewID,
                    request: .init(body: body, requestID: draft.requestID, anchor: draft.anchor))
            }
            guard self.scope == scope else {
                error = "The comment was saved on its original review host. Return to that review to see it."
                self.draft = nil
                draftBody = ""
                return
            }
            receive(saved)
            selectedThreadID = saved.id
            if filter != "all", filter != saved.state { filter = "all" }
            self.draft = nil
            draftBody = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleState(_ thread: PRReviewDiscussion) async {
        guard isAvailable, !isSaving, let client, let scope else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved = try await client.setPRReviewDiscussionState(reviewID: scope.reviewID, threadID: thread.id,
                request: .init(state: thread.isResolved ? "open" : "resolved", expectedVersion: thread.version, requestID: UUID().uuidString))
            guard self.scope == scope else { return }
            receive(saved)
        } catch {
            guard self.scope == scope else { return }
            self.error = error.localizedDescription
            // A concurrent reply or state change should be visible before the next explicit retry.
            await refresh()
        }
    }

    private func receive(_ thread: PRReviewDiscussion) {
        loadGeneration &+= 1
        isLoading = false
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            // An idempotency receipt can describe an earlier version than a poll.
            if threads[index].version <= thread.version { threads[index] = thread }
        }
        else { threads.append(thread) }
    }

    func inlineThreads(path: String, store: PRReviewStore) -> [PRReviewInlineThread] {
        guard scope?.machineID == store.currentMachineID, scope?.reviewID == store.selectedReviewID,
              let diff = store.currentDiff else { return [] }
        return threads.compactMap { thread in
            guard let anchor = thread.anchor, anchor.path == path,
                  anchor.baseSHA == diff.baseSHA, anchor.headSHA == diff.headSHA,
                  (anchor.comparisonSelection ?? .all) == store.comparisonSelection,
                  anchor.comparison == nil || anchor.comparison?.id == diff.comparison?.id,
                  let span = anchor.spans.last, let message = thread.messages.first else { return nil }
            return PRReviewInlineThread(id: thread.id, line: span.end, side: span.side, author: message.authorLabel,
                body: message.body, replyCount: max(0, thread.messages.count - 1), resolved: thread.isResolved)
        }
    }

    func showInDiff(_ thread: PRReviewDiscussion, store: PRReviewStore) async {
        guard let anchor = thread.anchor, let span = anchor.spans.first,
              scope?.machineID == store.currentMachineID, scope?.reviewID == store.selectedReviewID,
              let review = store.snapshot?.review,
              anchor.baseSHA == review.baseSHA, anchor.headSHA == review.headSHA else {
            error = "This thread belongs to an earlier revision. Its original code is preserved below."
            return
        }
        let origin = scope
        let selection = anchor.comparisonSelection ?? .all
        if selection != store.comparisonSelection {
            await store.loadComparison()
            guard scope == origin, store.comparisonCommits != nil else { return }
            store.selectComparison(selection)
            await store.loadComparison()
        }
        guard scope == origin, store.comparisonSelection == selection else {
            error = "The saved comparison is unavailable. The original code stays available in this thread."
            return
        }
        store.tab = .files
        store.search = ""
        store.impactFilter = .all
        store.hideViewed = false
        store.selectedPath = anchor.path
        await store.loadDiff(for: anchor.path)
        guard scope == origin, let diff = store.currentDiff,
              diff.baseSHA == anchor.baseSHA, diff.headSHA == anchor.headSHA,
              diff.files.contains(where: { $0.path == anchor.path }) else {
            error = "The saved file is unavailable in this comparison. Its original code is preserved below."
            return
        }
        store.highlight = (anchor.path, span.start, span.end, span.side)
        store.scroll(to: anchor.path, line: span.start, side: span.side)
        isPresented = false
    }
}
