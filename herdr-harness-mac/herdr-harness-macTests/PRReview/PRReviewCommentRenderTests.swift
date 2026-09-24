import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Offscreen visual verification for the local comment list, editor, and the
/// review-wide header control. Structural behavior lives in
/// `PRReviewCommentIntegrationTests`; these renders prove the layouts hold at
/// narrow widths and enlarged text, including earlier-revision warnings.
@MainActor
@Suite("PR Review comment renders", .serialized)
struct PRReviewCommentRenderTests {
    @Test("Comment list renders saved text, previews, and location metadata")
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

    @Test("Narrow and enlarged text keep long comments and paths readable")
    func rendersNarrowAndLargeText() async throws {
        let fixture = try listFixture()
        let narrow = try await HerdrRenderHarness.render(
            "pr-review-comments-narrow-xxlarge.png",
            size: CGSize(width: 600, height: 960),
            settlePasses: 12
        ) {
            PRReviewCommentsView(
                session: fixture.session,
                review: fixture.review,
                currentFilePaths: fixture.currentPaths
            )
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
        let commentStore = PRReviewCommentStore(inMemory: true)
        let store = demoStore()
        let draft = PRReviewCommentDraft(
            machineID: "demo",
            reviewID: PRReviewDemo.reviewID,
            prURL: "https://github.com/example-owner/garden-planner/pull/42",
            anchor: catalogAnchor(),
            body: "Header count should include this"
        )
        _ = try commentStore.insert(draft, diff: PRReviewDemo.diff())
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(machineID: "demo", reviewID: PRReviewDemo.reviewID)
        #expect(session.count(machineID: "demo", reviewID: PRReviewDemo.reviewID) == 1)

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

    private func catalogAnchor() -> PRReviewCommentAnchor {
        PRReviewCommentAnchor(
            baseSHA: "base",
            headSHA: "head",
            mergeBaseSHA: nil,
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 2)],
            code: "import Foundation\nstruct SeedCatalog {}"
        )
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
