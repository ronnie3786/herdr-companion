import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review comment links")
struct PRReviewCommentLinksTests {
    private let prURL = "https://github.com/example-owner/example-repo/pull/42"

    @Test("Canonical PR URLs keep GitHub pull requests and drop presentation noise")
    func canonicalPRURLs() {
        #expect(
            PRReviewCommentLinks.canonicalPRURL(from: "https://github.com/example-owner/example-repo/pull/42")?.absoluteString
                == "https://github.com/example-owner/example-repo/pull/42"
        )
        #expect(
            PRReviewCommentLinks.canonicalPRURL(from: "  https://github.com/example-owner/example-repo/pull/42/  ")?.absoluteString
                == "https://github.com/example-owner/example-repo/pull/42"
        )
        #expect(
            PRReviewCommentLinks.canonicalPRURL(from: "https://www.github.com/example-owner/example-repo/pull/42?diff=split#discussion_r1")?.absoluteString
                == "https://github.com/example-owner/example-repo/pull/42"
        )
        #expect(
            PRReviewCommentLinks.canonicalPRURL(from: "HTTPS://GitHub.com/example-owner/example-repo/pull/7")?.absoluteString
                == "https://github.com/example-owner/example-repo/pull/7"
        )
        #expect(
            PRReviewCommentLinks.canonicalPRURL(from: "https://github.com:443/example-owner/example-repo/pull/7")?.absoluteString
                == "https://github.com/example-owner/example-repo/pull/7"
        )
    }

    @Test("Unsafe schemes, credentials, and malformed pull request routes are rejected")
    func rejectsUnsafeReferences() {
        let rejected = [
            "http://github.com/example-owner/example-repo/pull/42",
            "javascript:alert(1)",
            "file:///tmp/example-repo/pull/42",
            "data:text/plain,https://github.com/example-owner/example-repo/pull/42",
            "https://user:token@github.com/example-owner/example-repo/pull/42",
            "https://github.com:8443/example-owner/example-repo/pull/42",
            "https://example.invalid/example-owner/example-repo/pull/42",
            "https://github.com.evil.invalid/example-owner/example-repo/pull/42",
            "https://github.com/example-owner/example-repo/pull",
            "https://github.com/example-owner/example-repo/pull/0",
            "https://github.com/example-owner/example-repo/pull/-2",
            "https://github.com/example-owner/example-repo/pull/two",
            "https://github.com/example-owner/example-repo/issues/42",
            "https://github.com/example-owner/example-repo/pull/42/../../other",
            "https://github.com/a/b/c/d/e/pull/42",
            "",
            "   ",
        ]
        for value in rejected {
            #expect(PRReviewCommentLinks.reference(from: value) == nil, "unexpected reference for \(value)")
        }
    }

    @Test("PR file anchors use independently verified SHA-256 of the file path")
    func filesURLVectors() throws {
        let ordinary = try #require(PRReviewCommentLinks.filesURL(
            prURL: prURL,
            currentPath: "Sources/Catalog/SeedCatalog.swift"
        ))
        #expect(ordinary.absoluteString == "https://github.com/example-owner/example-repo/pull/42/files#diff-66426456b6e21513c52f26fe28b70f316307086a4a6a32531a6249d4d959da16")

        let renamed = try #require(PRReviewCommentLinks.filesURL(
            prURL: prURL,
            currentPath: "Sources/Catalog/Seed Catalog.swift"
        ))
        #expect(renamed.absoluteString == "https://github.com/example-owner/example-repo/pull/42/files#diff-7e3058efb81db71af1deccb20b8360325f1448fdf9635a6972c20ab871c4ff3c")

        let deleted = try #require(PRReviewCommentLinks.filesURL(
            prURL: prURL,
            currentPath: "Legacy/Retired Seeds.swift"
        ))
        #expect(deleted.absoluteString == "https://github.com/example-owner/example-repo/pull/42/files#diff-e96c197189f1cc9be6ab07045c47e6ea21b512d6c48f9ff3b278ccfe50657abf")

        let unicode = try #require(PRReviewCommentLinks.filesURL(
            prURL: prURL,
            currentPath: "Sources/Résumé/種子 #1.swift"
        ))
        #expect(unicode.absoluteString == "https://github.com/example-owner/example-repo/pull/42/files#diff-2389f16c4adc4a098ac44a25a80174c5c10af78564a9f319a559b6dcef3e8896")

        #expect(PRReviewCommentLinks.filesURL(prURL: prURL, currentPath: "") == nil)
        #expect(PRReviewCommentLinks.filesURL(prURL: "javascript:alert(1)", currentPath: "Sources/A.swift") == nil)
    }

    @Test("Renamed files keep the current PR anchor and the old path for before-side source")
    func renamedFileAnchors() throws {
        let renamed = anchor(
            path: "Sources/Catalog/Seed Catalog.swift",
            oldPath: "Sources/old-path/renamed file.swift",
            mergeBaseSHA: "9999888877776666555544443333222211110000",
            spans: [
                PRReviewCommentSpan(side: .after, start: 4, end: 6),
                PRReviewCommentSpan(side: .before, start: 2, end: 3),
            ]
        )

        // The PR file anchor hashes the current path even though the file was
        // renamed. The before-side blob reads the retained old path.
        let files = try #require(PRReviewCommentLinks.filesURL(prURL: prURL, currentPath: renamed.path))
        #expect(files.absoluteString.hasSuffix("#diff-7e3058efb81db71af1deccb20b8360325f1448fdf9635a6972c20ab871c4ff3c"))

        let before = try #require(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: renamed,
            side: .before,
            span: renamed.spans[1]
        ))
        #expect(before.absoluteString == "https://github.com/example-owner/example-repo/blob/9999888877776666555544443333222211110000/Sources/old-path/renamed%20file.swift#L2-L3")

        let after = try #require(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: renamed,
            side: .after,
            span: renamed.spans[0]
        ))
        #expect(after.absoluteString == "https://github.com/example-owner/example-repo/blob/1111222233334444555566667777888899990000/Sources/Catalog/Seed%20Catalog.swift#L4-L6")
    }

    @Test("Deleted files keep their removed path and fall back to the base revision")
    func deletedFileAnchors() throws {
        let deleted = anchor(
            path: "Legacy/Retired Seeds.swift",
            oldPath: "",
            mergeBaseSHA: nil,
            spans: [PRReviewCommentSpan(side: .before, start: 9, end: 9)]
        )
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: deleted, side: .before) == deleted.baseSHA)

        let blob = try #require(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: deleted,
            side: .before,
            span: deleted.spans[0]
        ))
        #expect(blob.absoluteString == "https://github.com/example-owner/example-repo/blob/aaaa1111bbbb2222cccc3333dddd4444eeee5555/Legacy/Retired%20Seeds.swift#L9")

        // A single-line span uses GitHub's single-line fragment form.
        #expect(blob.absoluteString.hasSuffix("#L9"))

        let files = try #require(PRReviewCommentLinks.filesURL(prURL: prURL, currentPath: deleted.path))
        #expect(files.absoluteString.hasSuffix("#diff-e96c197189f1cc9be6ab07045c47e6ea21b512d6c48f9ff3b278ccfe50657abf"))
    }

    @Test("Unicode and special characters are percent-encoded per path component")
    func unicodePathEncoding() throws {
        let encoded = anchor(
            path: "Sources/Résumé/種子 #1.swift",
            oldPath: "",
            mergeBaseSHA: nil,
            spans: [PRReviewCommentSpan(side: .before, start: 3, end: 3)]
        )

        let blob = try #require(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: encoded,
            side: .before,
            span: encoded.spans[0]
        ))
        #expect(blob.absoluteString == "https://github.com/example-owner/example-repo/blob/aaaa1111bbbb2222cccc3333dddd4444eeee5555/Sources/R%C3%A9sum%C3%A9/%E7%A8%AE%E5%AD%90%20%231.swift#L3")
    }

    @Test("Merge-base SHAs win and invalid ones fall back to the base SHA")
    func revisionSHAFallback() {
        let merged = anchor(
            path: "Sources/Catalog/Seed Catalog.swift",
            oldPath: "",
            mergeBaseSHA: "abcdef0123456789abcdef0123456789abcdef01",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 1)]
        )
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: merged, side: .before) == "abcdef0123456789abcdef0123456789abcdef01")

        let blankMergeBase = anchor(
            path: "Sources/Catalog/Seed Catalog.swift",
            oldPath: "",
            mergeBaseSHA: "  ",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 1)]
        )
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: blankMergeBase, side: .before) == blankMergeBase.baseSHA)

        let invalidMergeBase = anchor(
            path: "Sources/Catalog/Seed Catalog.swift",
            oldPath: "",
            mergeBaseSHA: "not-a-commit",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 1)]
        )
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: invalidMergeBase, side: .before) == invalidMergeBase.baseSHA)

        var invalidBase = blankMergeBase
        invalidBase.baseSHA = "abc"
        invalidBase.mergeBaseSHA = nil
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: invalidBase, side: .before) == nil)
        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: invalidBase,
            side: .before
        ) == nil)
        // New files and added lines must still open the saved head even if the
        // original side has no usable revision.
        #expect(PRReviewCommentLinks.originalRevisionSHA(for: invalidBase, side: .after) == invalidBase.headSHA)
        var invalidHead = merged
        invalidHead.headSHA = "not-a-commit"
        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: invalidHead,
            side: .after
        ) == nil)
    }

    @Test("Invalid coordinates, sides, and paths produce no link")
    func rejectsInvalidCoordinates() {
        let valid = anchor(
            path: "Sources/Catalog/Seed Catalog.swift",
            oldPath: "Sources/old-path/renamed file.swift",
            spans: [PRReviewCommentSpan(side: .after, start: 4, end: 6)]
        )

        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: valid,
            side: .after,
            span: PRReviewCommentSpan(side: .after, start: 0, end: 6)
        ) == nil)
        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: valid,
            side: .after,
            span: PRReviewCommentSpan(side: .after, start: 6, end: 4)
        ) == nil)
        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: valid,
            side: .after,
            span: PRReviewCommentSpan(side: .before, start: 1, end: 1)
        ) == nil)
        #expect(PRReviewCommentLinks.originalRevisionBlobURL(
            prURL: prURL,
            anchor: valid,
            side: .after,
            span: PRReviewCommentSpan(side: .after, start: -3, end: -1)
        ) == nil)

        for path in ["", "/absolute/path.swift", "Sources/../secret.swift", "Sources/./hidden.swift", "Sources/Trailing/"] {
            var unsafe = valid
            unsafe.path = path
            #expect(PRReviewCommentLinks.filesURL(prURL: prURL, currentPath: path) == nil, "unexpected files link for \(path)")
            #expect(PRReviewCommentLinks.originalRevisionBlobURL(
                prURL: prURL,
                anchor: unsafe,
                side: .after
            ) == nil, "unexpected blob link for \(path)")
        }
    }

    @Test("Comment conveniences never carry comment text into a link")
    func commentLinks() throws {
        let comment = PRReviewComment(
            machineID: "synthetic-host",
            reviewID: "prr_review",
            prURL: prURL,
            anchor: anchor(
                path: "Sources/Catalog/Seed Catalog.swift",
                oldPath: "Sources/old-path/renamed file.swift",
                spans: [PRReviewCommentSpan(side: .before, start: 2, end: 3)]
            ),
            body: "The seeded value needs a guard."
        )

        let files = try #require(PRReviewCommentLinks.filesURL(for: comment))
        #expect(files.absoluteString.hasSuffix("#diff-7e3058efb81db71af1deccb20b8360325f1448fdf9635a6972c20ab871c4ff3c"))
        #expect(!files.absoluteString.contains("guard"))

        let blob = try #require(PRReviewCommentLinks.originalRevisionBlobURL(
            for: comment,
            side: .before,
            span: comment.anchor.spans[0]
        ))
        #expect(blob.absoluteString.hasSuffix("/Sources/old-path/renamed%20file.swift#L2-L3"))
        #expect(!blob.absoluteString.contains("guard"))
    }

    private func anchor(
        path: String,
        oldPath: String,
        mergeBaseSHA: String? = "9999888877776666555544443333222211110000",
        spans: [PRReviewCommentSpan]
    ) -> PRReviewCommentAnchor {
        PRReviewCommentAnchor(
            baseSHA: "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
            headSHA: "1111222233334444555566667777888899990000",
            mergeBaseSHA: mergeBaseSHA,
            path: path,
            oldPath: oldPath,
            spans: spans,
            code: "let seed = 1\n"
        )
    }
}
