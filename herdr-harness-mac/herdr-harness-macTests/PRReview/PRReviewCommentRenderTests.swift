import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Offscreen verification for host discussions and the retained previous-Mac
/// comment list/editor, including narrow widths and earlier-revision history.
@MainActor
@Suite("PR Review comment renders", .serialized)
struct PRReviewCommentRenderTests {
    @Test("Previous Mac comments still render saved text, previews, and locations")
    func rendersCommentList() async throws {
        let fixture = try listFixture()
        let result = try await HerdrRenderHarness.render(
            "pr-review-comments-list.png",
            size: CGSize(width: 700, height: 720),
            settlePasses: 12
        ) {
            PRReviewCommentsView(
                session: fixture.session,
                review: fixture.review,
                currentFilePaths: fixture.currentPaths
            )
            .environment(\.colorScheme, .dark)
        }

        result.expectSubstantial()
    }

    @Test("Host discussions render Human and Agent messages with original revision history")
    func rendersHostDiscussion() async throws {
        let fixture = await discussionFixture()
        let result = try await HerdrRenderHarness.render(
            "pr-review-host-discussions.png",
            size: CGSize(width: 900, height: 900),
            settlePasses: 12
        ) {
            PRReviewDiscussionView(session: fixture.session, store: fixture.store, canControl: true,
                                   previousCommentCount: 2, showPreviousComments: {})
                .environment(\.colorScheme, .dark)
        }
        result.expectSubstantial()
    }

    @Test("Narrow host discussions keep long paths, messages, and the reply composer visible")
    func rendersNarrowAndLargeText() async throws {
        let fixture = await discussionFixture()
        let thread = try #require(fixture.session.threads.first)
        fixture.session.beginReply(to: thread)
        fixture.session.draftBody = "  Human reply with **Markdown**\n\tand exact trailing spaces  \n"
        let narrow = try await HerdrRenderHarness.render(
            "pr-review-host-discussions-narrow-xxlarge.png",
            size: CGSize(width: 600, height: 960),
            settlePasses: 12
        ) {
            PRReviewDiscussionView(session: fixture.session, store: fixture.store, canControl: true,
                                   previousCommentCount: 2, showPreviousComments: {})
            .environment(\.herdrFontScale, .xxLarge)
            .environment(\.colorScheme, .dark)
        }

        narrow.expectSubstantial()
    }

    @Test("Editor renders a multiline draft with exact whitespace")
    func rendersEditor() async throws {
        let fixture = try editorFixture()
        fixture.session.draftBody = "  Keep the 🧪 seed\n\tand exact trailing spaces  \n\nAnd a final line."

        let result = try await HerdrRenderHarness.render(
            "pr-review-comment-editor.png",
            size: CGSize(width: 660, height: 560),
            settlePasses: 12
        ) {
            PRReviewCommentEditor(session: fixture.session)
                .environment(\.colorScheme, .dark)
        }

        result.expectSubstantial()
    }

    @Test("Editor renders a failed save with the draft still available")
    func rendersEditorSaveError() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "herdr-comment-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appending(path: "not-a-directory")
        try Data("synthetic block".utf8).write(to: blocker)
        let commentStore = PRReviewCommentStore(url: blocker.appending(path: "comments.json"))
        let fixture = try editorFixture(commentStore: commentStore)
        fixture.session.draftBody = "This draft must survive a failed save."
        fixture.session.save()
        #expect(fixture.session.saveError != nil)

        let result = try await HerdrRenderHarness.render(
            "pr-review-comment-editor-error.png",
            size: CGSize(width: 660, height: 620),
            settlePasses: 12
        ) {
            PRReviewCommentEditor(session: fixture.session)
                .environment(\.herdrFontScale, .xLarge)
                .environment(\.colorScheme, .dark)
        }

        result.expectSubstantial()
    }

    @Test("The review header renders the Comments control with its count")
    func rendersHeaderCommentsControl() async throws {
        let store = demoStore()
        let client = try #require(store.discussionClient)
        let threads = try await client.prReviewDiscussions(reviewID: PRReviewDemo.reviewID)
        #expect(threads.contains { $0.messages.first?.author == "agent" })
        let session = PRReviewCommentsSession(store: PRReviewCommentStore(inMemory: true))
        session.updateScope(machineID: "demo", reviewID: PRReviewDemo.reviewID)

        let result = try await HerdrRenderHarness.render(
            "pr-review-comments-header.png",
            size: CGSize(width: 1240, height: 820),
            settlePasses: 12
        ) {
            PRReviewContainerView(store: store, comments: session, canControl: true)
                .environment(\.colorScheme, .dark)
        }

        result.expectSubstantial()
    }

    // MARK: - Fixtures

    private func discussionFixture() async -> (store: PRReviewStore, session: PRReviewDiscussionSession) {
        let store = demoStore()
        let date = "2026-01-15T14:30:00Z"
        let thread = PRReviewDiscussion(
            id: "render-thread", reviewID: PRReviewDemo.reviewID, state: "open",
            anchor: .init(path: "Sources/Catalog/Seed Catalog With A Long Name.swift", baseSHA: "render-base",
                          headSHA: "render-earlier-head", spans: [.init(side: .before, start: 4, end: 5),
                                                                 .init(side: .after, start: 4, end: 7)],
                          codeExcerpt: "-let oldSeed = 1\n+let seed = 2\n"),
            outdated: true, createdAt: date, updatedAt: date, version: 4,
            messages: [
                .init(id: "render-agent", author: "agent", body: "Swift reviewer: How will an empty catalog be represented during sync?",
                      createdAt: date, updatedAt: date),
                .init(id: "render-human", author: "human", body: "  Keep the 🧪 seed\n\tand exact trailing spaces  \n",
                      createdAt: date, updatedAt: date),
            ],
            history: [
                .init(id: "render-created", action: "created", author: "agent", createdAt: date,
                      baseSHA: "render-base", headSHA: "render-earlier-head"),
                .init(id: "render-edited", action: "edited", author: "human", createdAt: date,
                      baseSHA: "render-base", headSHA: "render-earlier-head", previousBody: "Earlier human response."),
            ]
        )
        let session = PRReviewDiscussionSession()
        session.configure(scope: .init(machineID: "demo", reviewID: PRReviewDemo.reviewID, generation: store.guideConnectionGeneration),
                          client: DiscussionRenderClient(threads: [thread]), available: true)
        await session.refresh()
        return (store, session)
    }

    private func listFixture() throws -> (
        session: PRReviewCommentsSession,
        review: PRReviewSummary,
        currentPaths: Set<String>
    ) {
        let commentStore = PRReviewCommentStore(inMemory: true)
        let currentDiff = try renderDiff(headSHA: "render-head")
        let earlierDiff = try renderDiff(headSHA: "render-head-earlier")

        func insert(
            path: String,
            headSHA: String,
            spans: [PRReviewCommentSpan],
            code: String,
            body: String,
            diff: PRReviewDiff
        ) throws {
            let anchor = PRReviewCommentAnchor(
                baseSHA: "render-base",
                headSHA: headSHA,
                mergeBaseSHA: nil,
                path: path,
                oldPath: "",
                spans: spans,
                code: code
            )
            let draft = PRReviewCommentDraft(
                machineID: "render-host",
                reviewID: "prr_render",
                prURL: "https://github.com/example-owner/example-repo/pull/42",
                anchor: anchor,
                body: body
            )
            _ = try commentStore.insert(draft, diff: diff)
        }

        try insert(
            path: "Sources/Catalog/SeedCatalog.swift",
            headSHA: "render-head",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 2)],
            code: "import Foundation\nlet seed = 1",
            body: "  Keep the 🧪 seed\n\tand exact trailing spaces  \n",
            diff: currentDiff
        )
        try insert(
            path: "Sources/Résumé/種子 #1.swift",
            headSHA: "render-head-earlier",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 1)],
            code: "// Unicode path preview",
            body: "This was saved against the earlier revision.",
            diff: earlierDiff
        )
        try insert(
            path: "Sources/Résumé/種子 #1.swift",
            headSHA: "render-head",
            spans: [PRReviewCommentSpan(side: .after, start: 2, end: 2)],
            code: "struct SeedArchive {}",
            body: "The current revision no longer lists this file.",
            diff: currentDiff
        )

        var review = PRReviewDemo.snapshot().review
        review.id = "prr_render"
        review.baseSHA = "render-base"
        review.headSHA = "render-head"
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(machineID: "render-host", reviewID: "prr_render")
        return (session, review, ["Sources/Catalog/SeedCatalog.swift"])
    }

    private func editorFixture(
        commentStore: PRReviewCommentStore? = nil
    ) throws -> (store: PRReviewStore, session: PRReviewCommentsSession) {
        let store = demoStore()
        let session = PRReviewCommentsSession(
            store: commentStore ?? PRReviewCommentStore(inMemory: true)
        )
        session.updateScope(from: store)
        let selection = PRReviewSelection(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [.init(side: .after, start: 1, end: 2)],
            text: "import Foundation\nstruct SeedCatalog {}"
        )
        #expect(session.beginComposition(selection: selection, store: store))
        return (store, session)
    }

    private func demoStore() -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = "Sources/Catalog/SeedCatalog.swift"
        store.diff = PRReviewDemo.diff()
        return store
    }

    private func renderDiff(headSHA: String) throws -> PRReviewDiff {
        let json = """
        {"ok":true,"review_id":"prr_render","base_sha":"render-base","head_sha":"\(headSHA)","truncated":false,"files":[
          {"path":"Sources/Catalog/SeedCatalog.swift","old_path":"","status":"modified","additions":1,"deletions":1,"binary":false,"truncated":false,"hunks":[
            {"old_start":1,"old_lines":3,"new_start":1,"new_lines":3,"header":"@@","lines":[
              {"kind":"context","old_number":1,"new_number":1,"text":"import Foundation"},
              {"kind":"del","old_number":2,"new_number":null,"text":"let oldSeed = 1"},
              {"kind":"add","old_number":null,"new_number":2,"text":"let seed = 1"},
              {"kind":"context","old_number":3,"new_number":3,"text":"// end"}
            ]}
          ]},
          {"path":"Sources/Résumé/種子 #1.swift","old_path":"","status":"added","additions":2,"deletions":0,"binary":false,"truncated":false,"hunks":[
            {"old_start":0,"old_lines":0,"new_start":1,"new_lines":2,"header":"@@","lines":[
              {"kind":"add","old_number":null,"new_number":1,"text":"// Unicode path preview"},
              {"kind":"add","old_number":null,"new_number":2,"text":"struct SeedArchive {}"}
            ]}
          ]}
        ]}
        """
        return try JSONDecoder().decode(PRReviewDiff.self, from: Data(json.utf8))
    }
}

private actor DiscussionRenderClient: PRReviewDiscussionClient {
    let threads: [PRReviewDiscussion]
    init(threads: [PRReviewDiscussion]) { self.threads = threads }
    func prReviewDiscussions(reviewID: String) async throws -> [PRReviewDiscussion] { threads }
    func createPRReviewDiscussion(reviewID: String, request: PRReviewDiscussionCreate) async throws -> PRReviewDiscussion {
        throw APIError.invalidResponse
    }
    func replyToPRReviewDiscussion(reviewID: String, threadID: String, request: PRReviewDiscussionReply) async throws -> PRReviewDiscussion {
        throw APIError.invalidResponse
    }
    func setPRReviewDiscussionState(reviewID: String, threadID: String, request: PRReviewDiscussionStateChange) async throws -> PRReviewDiscussion {
        throw APIError.invalidResponse
    }
}
