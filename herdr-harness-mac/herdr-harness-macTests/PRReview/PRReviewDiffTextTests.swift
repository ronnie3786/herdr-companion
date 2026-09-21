import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("PR Review diff text")
struct PRReviewDiffTextTests {
    @Test("Unchanged diff identity preserves the attributed text selection") @MainActor
    func unchangedRenderIdentitySkipsTextReplacement() {
        let coordinator = PRReviewDiffText.Coordinator()
        let identity = PRReviewDiffText.Coordinator.RenderIdentity(
            path: "Sources/Garden.swift",
            oldPath: nil,
            headSHA: "fictional-head",
            fontScale: .medium
        )

        #expect(coordinator.shouldSetAttributedString(for: identity))
        coordinator.lastRenderedIdentity = identity
        #expect(!coordinator.shouldSetAttributedString(for: identity))
        #expect(coordinator.shouldSetAttributedString(for: .init(
            path: identity.path,
            oldPath: identity.oldPath,
            headSHA: "new-fictional-head",
            fontScale: identity.fontScale
        )))
    }

    @Test("Selection text excludes the line-number gutter")
    func selectionExcludesGutter() {
        let file = PRReviewDemo.diff().files[0]
        let rendered = PRReviewDiffRenderer.render(file: file)
        let selection = rendered.index.selection(
            path: file.path,
            oldPath: file.oldPath ?? "",
            text: rendered.text.string as NSString,
            range: NSRange(location: 0, length: rendered.text.length)
        )

        #expect(selection?.text.contains("│") == false)
        #expect(selection?.text.contains("struct SeedCatalog {}") == true)
    }

    @Test("A unified selection splits old and new spans")
    func unifiedSelectionSplitsSides() {
        let text = "old\nnew\n"
        let index = PRReviewLineIndex(entries: [
            .init(utf16Offset: 0, length: 4, side: .before, oldLine: 7, newLine: nil, kind: "del"),
            .init(utf16Offset: 4, length: 4, side: .after, oldLine: nil, newLine: 8, kind: "add"),
        ])
        let selection = index.selection(path: "Sources/Seed.swift", oldPath: "", text: text as NSString,
                                        range: NSRange(location: 0, length: 7))
        #expect(selection?.spans == [.init(side: .before, start: 7, end: 7), .init(side: .after, start: 8, end: 8)])
    }

    @Test("Hunk headers do not have a review side")
    func hunkHeadersHaveNoSide() {
        let rendered = PRReviewDiffRenderer.render(file: PRReviewDemo.diff().files[0])
        let hunkEntries = rendered.index.entries.filter { $0.kind == "hunk" }

        #expect(!hunkEntries.isEmpty)
        #expect(hunkEntries.allSatisfy { $0.side == nil })
    }
}
