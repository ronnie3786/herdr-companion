import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("PR Review shared diff inputs")
struct PRReviewDiffStyleTests {
    @Test("Embedded Git supplies surfaces, not a second renderer theme") @MainActor
    func embeddedGitUsesSharedRendererVariables() {
        let css = HerdrWebTheme.css
        #expect(css.contains("--herdr-diff-background"))
        #expect(css.contains("--herdr-diff-gutter-background"))
        #expect(!css.contains("--diffs-line-height:"))
        #expect(!css.contains("--diffs-bg-addition-override:"))
    }

    @Test("Structured hunks produce valid headers, including partial and legacy snapshots")
    func patchPreservesSourceText() {
        var file = PRReviewDemo.diff().files[0]
        file.hunks = [file.hunks[0]]
        file.hunks[0].lines = [
            PRReviewDiffLine(kind: "del", oldNumber: 1, newNumber: nil, text: "let status = \"😀\""),
            PRReviewDiffLine(kind: "add", oldNumber: nil, newNumber: 1, text: ""),
        ]
        let patch = PRReviewDiffRenderer.patch(for: file)
        #expect(patch.contains("@@ -1,1 +1,1 @@\n-let status = \"😀\"\n+\n"))
    }

    @Test("Changed content at identical SHAs has a different renderer identity")
    func fullerPatchInvalidatesIdentity() {
        var file = PRReviewDemo.diff().files[0]
        let before = PRReviewDiffRenderer.payload(file: file, identity: "same-shas")
        file.hunks[0].lines[0].text = "import SyntheticGarden"
        let after = PRReviewDiffRenderer.payload(file: file, identity: "same-shas")
        #expect(before.identity != after.identity)
    }

    @Test("Filenames cannot inject patch metadata")
    func quotedFilename() {
        var file = PRReviewDemo.diff().files[0]
        file.path = "Sources/Garden\n--- fake.swift"
        let patch = PRReviewDiffRenderer.patch(for: file)
        #expect(patch.hasPrefix("diff --git \"a/Sources/Garden\\012--- fake.swift\" \"b/Sources/Garden\\012--- fake.swift\"\n"))
    }
}
