import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review comment store")
struct PRReviewCommentStoreTests {
    // MARK: - Persistence

    @Test("Comments, exact text, anchors, and permissions survive relaunch")
    func persistsExactContentAndPermissions() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "PRReview/pr-review-comments-v1.json")
        let store = PRReviewCommentStore(url: url)
        let diff = try makeDiff()
        let body = "  Keep the 🧪 seed\n\tand the exact trailing spaces  \n"
        let anchor = makeAnchor()

        let comment = try store.insert(
            makeDraft(anchor: anchor, body: body),
            diff: diff,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(comment.editVersion == 1)
        #expect(comment.prURL == "https://github.com/example-owner/example-repo/pull/42")
        #expect(comment.body == body)
        #expect(comment.anchor == anchor)
        #expect(store.loadError == nil)
        #expect(store.writeError == nil)

        let reopened = PRReviewCommentStore(url: url)
        #expect(reopened.loadError == nil)
        #expect(reopened.comments == [comment])
        #expect(reopened.comments(machineID: "synthetic-host", reviewID: "prr_review").count == 1)
        #expect(reopened.comments(machineID: "synthetic-host", reviewID: "other-review").isEmpty)

        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700)
        let filePermissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(filePermissions == 0o600)
    }

    @Test("Edits persist and stale versions cannot overwrite newer text")
    func editUsesStaleVersionDetection() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let store = PRReviewCommentStore(url: url)
        let diff = try makeDiff()
        let first = try store.insert(makeDraft(), diff: diff, createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        let edited = try store.edit(
            id: first.id,
            body: "First edit with  preserved spacing.  ",
            expecting: 1,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        #expect(edited.editVersion == 2)
        #expect(edited.createdAt == first.createdAt)
        #expect(edited.updatedAt == Date(timeIntervalSince1970: 1_700_000_100))

        #expect(throws: PRReviewCommentStoreError.staleEdit(currentVersion: 2)) {
            try store.edit(id: first.id, body: "Stale overwrite", expecting: 1)
        }
        #expect(store.comment(id: first.id)?.body == "First edit with  preserved spacing.  ")
        #expect(store.comment(id: first.id)?.editVersion == 2)

        #expect(throws: PRReviewCommentStoreError.commentNotFound) {
            try store.edit(id: UUID(), body: "Missing comment", expecting: 1)
        }
        #expect(throws: PRReviewCommentStoreError.blankBody) {
            try store.edit(id: first.id, body: " \n\t ", expecting: 2)
        }
        #expect(store.comment(id: first.id)?.editVersion == 2)

        let reopened = PRReviewCommentStore(url: url)
        #expect(reopened.comment(id: first.id)?.body == edited.body)
        #expect(reopened.comment(id: first.id)?.editVersion == 2)
    }

    @Test("Blank bodies are rejected and valid text is never trimmed")
    func rejectsBlankBodyWithoutTrimming() throws {
        let store = PRReviewCommentStore(inMemory: true)
        let diff = try makeDiff()

        #expect(throws: PRReviewCommentStoreError.blankBody) {
            try store.insert(makeDraft(body: "   \n\t  "), diff: diff)
        }
        #expect(store.comments.isEmpty)

        let body = "  leading and trailing stay  "
        let comment = try store.insert(makeDraft(body: body), diff: diff)
        #expect(comment.body == body)
        #expect(store.comment(id: comment.id)?.body == body)
    }

    // MARK: - Corrupt storage

    @Test("Corrupt storage is preserved and refuses every write")
    func corruptStorageIsPreservedAndBlocksWrites() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let original = Data("{\"version\":1,\"comments\":[".utf8)
        try original.write(to: url)

        let store = PRReviewCommentStore(url: url)
        #expect(store.loadError == .corruptStorage)
        #expect(store.comments.isEmpty)
        #expect(throws: PRReviewCommentStoreError.storageUnavailable) {
            try store.insert(makeDraft(), diff: try makeDiff())
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Unknown storage versions are preserved and refuse every write")
    func unknownStorageVersionIsPreservedAndBlocksWrites() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let original = Data("{\"version\":99,\"comments\":[]}".utf8)
        try original.write(to: url)

        let store = PRReviewCommentStore(url: url)
        #expect(store.loadError == .unsupportedStorageVersion(99))
        #expect(store.comments.isEmpty)
        #expect(throws: PRReviewCommentStoreError.storageUnavailable) {
            try store.insert(makeDraft(), diff: try makeDiff())
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Structurally corrupt records are preserved rather than dropped")
    func structurallyCorruptStorageIsPreserved() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let original = Data("""
        {"version":1,"comments":[{"id":"00000000-0000-0000-0000-000000000001","machineID":"","reviewID":"","prURL":"","anchor":{"baseSHA":"","headSHA":"","mergeBaseSHA":null,"path":"","oldPath":"","spans":[],"code":""},"body":"","createdAt":0,"updatedAt":0,"editVersion":0}]}
        """.utf8)
        try original.write(to: url)

        let store = PRReviewCommentStore(url: url)
        #expect(store.loadError == .corruptStorage)
        #expect(store.comments.isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    // MARK: - Failed writes

    @Test("A failed write rolls memory back and a retry can succeed")
    func failedWriteRollsBackMemoryAndRetrySucceeds() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appending(path: "not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let store = PRReviewCommentStore(url: blocker.appending(path: "comments.json"))
        let diff = try makeDiff()

        #expect(throws: PRReviewCommentStoreError.writeFailed) {
            try store.insert(makeDraft(), diff: diff)
        }
        #expect(store.comments.isEmpty)
        #expect(store.writeError == .writeFailed)

        try FileManager.default.removeItem(at: blocker)
        let comment = try store.insert(makeDraft(), diff: diff)
        #expect(store.comments == [comment])
        #expect(store.writeError == nil)
    }

    // MARK: - Scoping

    @Test("Duplicate display labels or PR numbers on distinct hosts and reviews never mix")
    func scopedListingNeverMixesHostsOrReviews() throws {
        let store = PRReviewCommentStore(inMemory: true)
        let sharedDiff = try makeDiff(reviewID: "prr_shared")
        let otherDiff = try makeDiff(reviewID: "prr_other")

        let hostA = try store.insert(makeDraft(machineID: "host-a", reviewID: "prr_shared"), diff: sharedDiff)
        let hostB = try store.insert(makeDraft(machineID: "host-b", reviewID: "prr_shared"), diff: sharedDiff)
        let otherReview = try store.insert(makeDraft(machineID: "host-a", reviewID: "prr_other"), diff: otherDiff)

        #expect(store.comments(machineID: "host-a", reviewID: "prr_shared").map(\.id) == [hostA.id])
        #expect(store.comments(machineID: "host-b", reviewID: "prr_shared").map(\.id) == [hostB.id])
        #expect(store.comments(machineID: "host-a", reviewID: "prr_other").map(\.id) == [otherReview.id])
        #expect(store.comments(machineID: "host-a", reviewID: "missing").isEmpty)
        #expect(store.comments(machineID: "host-a", reviewID: "prr_shared", path: makeAnchor().path).map(\.id) == [hostA.id])
        #expect(store.comments(machineID: "host-a", reviewID: "prr_shared", path: "Sources/Other.swift").isEmpty)
        #expect(store.comments.count == 3)
    }

    // MARK: - Anchors and revisions

    @Test("Mixed before and after spans round-trip without rewriting sides")
    func mixedSideAnchorsRoundTrip() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let store = PRReviewCommentStore(url: url)
        let anchor = makeAnchor(spans: [
            PRReviewCommentSpan(side: .after, start: 1, end: 2),
            PRReviewCommentSpan(side: .before, start: 2, end: 2),
        ])
        #expect(anchor.problem(against: try makeDiff()) == nil)
        #expect(anchor.beforePath == "Sources/old-path/renamed file.swift")

        let comment = try store.insert(makeDraft(anchor: anchor), diff: try makeDiff())
        #expect(comment.anchor.spans.map(\.side) == [.after, .before])

        let reopened = PRReviewCommentStore(url: url)
        #expect(reopened.comment(id: comment.id)?.anchor == anchor)
        #expect(reopened.comment(id: comment.id)?.anchor.spans == anchor.spans)
    }

    @Test("A revision change never moves a saved anchor and blocks new stale anchors")
    func revisionRetentionKeepsOriginalAnchor() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let store = PRReviewCommentStore(url: url)
        let anchor = makeAnchor()
        let comment = try store.insert(makeDraft(anchor: anchor), diff: try makeDiff())
        let newerDiff = try makeDiff(headSHA: "synthetic-head-2")

        #expect(anchor.problem(against: newerDiff) == .revisionMismatch)
        #expect(comment.anchor.code == anchor.code)
        #expect(comment.anchor.headSHA == "synthetic-head")
        #expect(throws: PRReviewCommentStoreError.invalidAnchor(.revisionMismatch)) {
            try store.insert(makeDraft(anchor: anchor), diff: newerDiff)
        }

        let reopened = PRReviewCommentStore(url: url)
        #expect(reopened.comment(id: comment.id)?.anchor == anchor)
        #expect(reopened.comment(id: comment.id)?.anchor.headSHA == "synthetic-head")
    }

    @Test("Anchors are validated against the loaded diff before anything is saved")
    func anchorValidationRejectsMismatchedDiff() throws {
        let store = PRReviewCommentStore(inMemory: true)
        let diff = try makeDiff()

        func expect(_ problem: PRReviewCommentAnchorProblem, anchor: PRReviewCommentAnchor, diff: PRReviewDiff) {
            #expect(anchor.problem(against: diff) == problem)
            #expect(throws: PRReviewCommentStoreError.invalidAnchor(problem)) {
                try store.insert(makeDraft(anchor: anchor), diff: diff)
            }
            #expect(store.comments.isEmpty)
        }

        expect(.emptyPath, anchor: makeAnchor(path: ""), diff: diff)
        expect(.emptyCode, anchor: makeAnchor(code: ""), diff: diff)
        expect(.emptySpans, anchor: makeAnchor(spans: []), diff: diff)
        expect(.missingFile, anchor: makeAnchor(path: "Sources/Missing.swift", oldPath: ""), diff: diff)

        let binary = makeAnchor(path: "Assets/Logo.png", oldPath: "", spans: [.init(side: .after, start: 1, end: 1)])
        expect(.binaryFile, anchor: binary, diff: diff)

        var partialDiff = diff
        partialDiff.files[0].truncated = true
        expect(.partialDiff, anchor: makeAnchor(), diff: partialDiff)

        expect(.oldPathMismatch, anchor: makeAnchor(oldPath: "Sources/other-old.swift"), diff: diff)
        expect(.invalidSpan, anchor: makeAnchor(spans: [.init(side: .after, start: 3, end: 1)]), diff: diff)
        expect(.lineNotFound, anchor: makeAnchor(spans: [.init(side: .after, start: 7, end: 7)]), diff: diff)
        expect(.lineNotFound, anchor: makeAnchor(spans: [.init(side: .before, start: 9, end: 9)]), diff: diff)

        // A deleted file keeps its own path on the before side.
        let deleted = makeAnchor(
            path: "Legacy/Retired Seeds.swift",
            oldPath: "",
            spans: [.init(side: .before, start: 9, end: 9)]
        )
        #expect(deleted.problem(against: diff) == nil)
        #expect(try store.insert(makeDraft(anchor: deleted), diff: diff).anchor == deleted)
    }

    @Test("Draft identity, URL, review, and duplicate checks run before saving")
    func draftValidationRejectsInvalidFields() throws {
        let store = PRReviewCommentStore(inMemory: true)
        let diff = try makeDiff()

        #expect(throws: PRReviewCommentStoreError.missingScope) {
            try store.insert(makeDraft(machineID: "  "), diff: diff)
        }
        #expect(throws: PRReviewCommentStoreError.invalidPRURL) {
            try store.insert(makeDraft(prURL: "http://github.com/example-owner/example-repo/pull/42"), diff: diff)
        }
        #expect(throws: PRReviewCommentStoreError.invalidPRURL) {
            try store.insert(makeDraft(prURL: "javascript:alert(1)"), diff: diff)
        }
        #expect(throws: PRReviewCommentStoreError.reviewMismatch) {
            try store.insert(makeDraft(reviewID: "prr_other"), diff: diff)
        }

        let id = UUID()
        _ = try store.insert(makeDraft(), diff: diff, id: id)
        #expect(throws: PRReviewCommentStoreError.duplicateComment) {
            try store.insert(makeDraft(), diff: diff, id: id)
        }
        #expect(store.comments.count == 1)
    }

    @Test("Saved comments are never pruned automatically")
    func noAutomaticPruning() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let store = PRReviewCommentStore(url: url)
        let diff = try makeDiff()

        for index in 0..<40 {
            _ = try store.insert(
                makeDraft(body: "Comment \(index)"),
                diff: diff,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        #expect(store.comments.count == 40)

        let reopened = PRReviewCommentStore(url: url)
        #expect(reopened.comments.count == 40)
        #expect(reopened.comments.first?.body == "Comment 0")
        #expect(reopened.comments.last?.body == "Comment 39")
    }

    // MARK: - Fixtures

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "herdr-pr-comment-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeDiff(reviewID: String = "prr_review", headSHA: String = "synthetic-head") throws -> PRReviewDiff {
        let json = """
        {"ok":true,"review_id":"\(reviewID)","base_sha":"synthetic-base","head_sha":"\(headSHA)","truncated":false,"files":[
          {"path":"Sources/Catalog/Seed Catalog.swift","old_path":"Sources/old-path/renamed file.swift","status":"renamed","additions":1,"deletions":1,"binary":false,"truncated":false,"hunks":[
            {"old_start":1,"old_lines":3,"new_start":1,"new_lines":3,"header":"@@ -1,3 +1,3 @@","lines":[
              {"kind":"context","old_number":1,"new_number":1,"text":"import Foundation"},
              {"kind":"del","old_number":2,"new_number":null,"text":"let old = 1"},
              {"kind":"add","old_number":null,"new_number":2,"text":"let seed = 1"},
              {"kind":"context","old_number":3,"new_number":3,"text":"// end"}
            ]}
          ]},
          {"path":"Legacy/Retired Seeds.swift","old_path":"","status":"deleted","additions":0,"deletions":1,"binary":false,"truncated":false,"hunks":[
            {"old_start":9,"old_lines":1,"new_start":0,"new_lines":0,"header":"@@ -9,1 +0,0 @@","lines":[
              {"kind":"del","old_number":9,"new_number":null,"text":"legacy"}
            ]}
          ]},
          {"path":"Assets/Logo.png","old_path":"","status":"modified","additions":0,"deletions":0,"binary":true,"truncated":false,"hunks":[]}
        ]}
        """
        return try JSONDecoder().decode(PRReviewDiff.self, from: Data(json.utf8))
    }

    private func makeAnchor(
        path: String = "Sources/Catalog/Seed Catalog.swift",
        oldPath: String = "Sources/old-path/renamed file.swift",
        spans: [PRReviewCommentSpan] = [
            PRReviewCommentSpan(side: .after, start: 1, end: 2),
            PRReviewCommentSpan(side: .before, start: 2, end: 2),
        ],
        code: String = "import Foundation\nlet seed = 1\n"
    ) -> PRReviewCommentAnchor {
        PRReviewCommentAnchor(
            baseSHA: "synthetic-base",
            headSHA: "synthetic-head",
            mergeBaseSHA: "synthetic-merge-base",
            path: path,
            oldPath: oldPath,
            spans: spans,
            code: code
        )
    }

    private func makeDraft(
        machineID: String = "synthetic-host",
        reviewID: String = "prr_review",
        prURL: String = "https://github.com/example-owner/example-repo/pull/42",
        anchor: PRReviewCommentAnchor? = nil,
        body: String = "Please double-check this seed."
    ) -> PRReviewCommentDraft {
        PRReviewCommentDraft(
            machineID: machineID,
            reviewID: reviewID,
            prURL: prURL,
            anchor: anchor ?? makeAnchor(),
            body: body
        )
    }
}
