import AppKit
import SwiftUI
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
            baseSHA: "fictional-base",
            headSHA: "fictional-head",
            fontScale: .medium
        )

        #expect(coordinator.shouldSetAttributedString(for: identity))
        coordinator.lastRenderedIdentity = identity
        #expect(!coordinator.shouldSetAttributedString(for: identity))
        #expect(coordinator.shouldSetAttributedString(for: .init(
            path: identity.path,
            oldPath: identity.oldPath,
            baseSHA: "new-fictional-base",
            headSHA: identity.headSHA,
            fontScale: identity.fontScale
        )))
        #expect(coordinator.shouldSetAttributedString(for: .init(
            path: identity.path,
            oldPath: identity.oldPath,
            baseSHA: identity.baseSHA,
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

    @Test("Deleted textual files retain removal code and old line mapping")
    func deletedTextRendersRemovalHunks() {
        var file = PRReviewDemo.diff().files[0]
        file.status = "deleted"
        file.hunks = [file.hunks[1]]

        let rendered = PRReviewDiffRenderer.render(file: file)

        #expect(rendered.text.string.contains("-old"))
        #expect(rendered.index.entries.contains {
            $0.kind == "del" && $0.side == .before && $0.oldLine == 8 && $0.newLine == nil
        })
    }

    @Test("Long code expands the native document in both scrolling directions") @MainActor
    func longCodeSizesScrollableDocument() async throws {
        var file = PRReviewDemo.diff().files[0]
        var lines: [PRReviewDiffLine] = []
        for number in 1...80 {
            var line = file.hunks[0].lines[0]
            line.oldNumber = number
            line.newNumber = number
            line.text = "let syntheticValue\(number) = \"" + String(repeating: "garden", count: 35) + "\""
            lines.append(line)
        }
        file.hunks[0].lines = lines
        file.hunks = [file.hunks[0]]

        let size = CGSize(width: 640, height: 320)
        let hosting = NSHostingView(rootView: PRReviewDiffText(file: file).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }

        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        let textView = try #require(descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first)
        let clip = try #require(textView.enclosingScrollView?.contentView)

        #expect(textView.frame.width > clip.bounds.width)
        #expect(textView.frame.height > clip.bounds.height)
        #expect(textView.string.contains("syntheticValue80"))
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
