import AppKit
import SwiftUI
import Testing
import WebKit
@testable import herdr_harness_mac

@Suite("PR Review shared diff renderer", .serialized)
struct PRReviewDiffTextTests {
    @Test("Unchanged diff identity preserves the web renderer") @MainActor
    func unchangedRenderIdentitySkipsReplacement() {
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
    }

    @Test("PR hunks become a one-file Git patch with side mapping")
    func buildsPatch() {
        let file = PRReviewDemo.diff().files[0]
        let patch = PRReviewDiffRenderer.patch(for: file)

        #expect(patch.contains("diff --git a/\(file.path) b/\(file.path)"))
        #expect(patch.contains("@@"))
        #expect(patch.contains("+struct SeedCatalog {}"))
        #expect(PRReviewDiffRenderer.plainText(for: file).contains("struct SeedCatalog {}"))
    }

    @Test("Added and deleted files preserve Git metadata")
    func fileStatusMetadata() {
        var added = PRReviewDemo.diff().files[0]
        added.status = "added"
        #expect(PRReviewDiffRenderer.patch(for: added).contains("--- /dev/null"))

        var deleted = added
        deleted.status = "deleted"
        #expect(PRReviewDiffRenderer.patch(for: deleted).contains("+++ /dev/null"))
    }

    @Test("Deleted files render removal hunks with original-side line numbers")
    @MainActor
    func deletedFileRemovalHunksKeepOldSideEvidence() async throws {
        let file = deletedFixture()
        let patch = PRReviewDiffRenderer.patch(for: file)
        #expect(patch.contains("deleted file mode 100644"))
        #expect(patch.contains("+++ /dev/null"))
        #expect(patch.contains("-let obsoleteSeed = 1"))

        let mounted = mount(file: file)
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.isRendererReady && mounted.view.renderedIdentity != nil }
        try #require(ready)
        #expect(mounted.view.renderedPlainText.contains("-let obsoleteSeed = 1"))
        #expect(mounted.view.renderedPlainText.contains("-let legacySeed = 2"))

        var result: [String: Any]?
        for _ in 0..<100 {
            if let evaluated = try? await mounted.view.evaluateJavaScript("""
            (() => {
              const root = document.querySelector('diffs-container')?.shadowRoot;
              if (!root) return null;
              const line = root.querySelector('[data-line="6"]');
              if (!line) return null;
              return {
                type: line.getAttribute('data-line-type'),
                text: line.textContent
              };
            })()
            """) {
                result = evaluated as? [String: Any]
            }
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let values = try #require(result)
        #expect((values["type"] as? String)?.contains("deletion") == true)
        #expect((values["text"] as? String)?.contains("let obsoleteSeed = 1") == true)
    }

    @Test("A before-side highlight marks the removal line in a deleted file")
    @MainActor
    func beforeSideHighlightMarksDeletedRemovalLine() async throws {
        let mounted = mount(
            file: deletedFixture(),
            size: CGSize(width: 700, height: 260),
            highlight: (start: 6, end: 6, side: .before)
        )
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.isRendererReady && mounted.view.renderedIdentity != nil }
        try #require(ready)

        var marked = false
        for _ in 0..<100 {
            if let evaluated = try? await mounted.view.evaluateJavaScript("""
            (() => {
              const root = document.querySelector('diffs-container')?.shadowRoot;
              const line = root?.querySelector('[data-line="6"]');
              return line?.hasAttribute('data-selected-line') === true;
            })()
            """) {
                marked = (evaluated as? Bool) ?? false
            }
            if marked { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(marked, "A before-side highlight must mark the deletion line, not an after-side line")
    }

    @Test("Payload carries font scale and highlighted side")
    func payloadCarriesPresentationInputs() throws {
        let payload = PRReviewDiffRenderer.payload(
            file: PRReviewDemo.diff().files[0],
            identity: "synthetic-identity",
            fontScale: .xxLarge,
            highlight: (start: 2, end: 4, side: .before)
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let highlight = try #require(object["highlight"] as? [String: Any])

        #expect(object["fontScale"] as? Double == HerdrFontScale.xxLarge.rawValue)
        #expect(highlight["side"] as? String == "old")
        #expect(highlight["start"] as? Int == 2)
    }

    @Test("Bundled renderer loads offline and syntax-highlights Swift") @MainActor
    func bundledRendererLoads() async throws {
        let mounted = mount(file: PRReviewDemo.diff().files[0])
        defer { mounted.window.close() }

        let ready = await waitUntil {
            mounted.view.isRendererReady && mounted.view.renderedIdentity != nil
        }
        try #require(ready)
        #expect(mounted.view.renderedPlainText.contains("struct SeedCatalog {}"))
        var syntaxColors = 0
        for _ in 0..<100 {
            syntaxColors = (try? await mounted.view.evaluateJavaScript("new Set([...document.querySelector('diffs-container').shadowRoot.querySelectorAll('[data-line] span')].map(s => getComputedStyle(s).color)).size")) as? Int ?? 0
            if syntaxColors > 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(syntaxColors > 1, "The actual Swift code must contain multiple syntax colors, not just colored diff rows")

        let result = try await mounted.view.evaluateJavaScript("""
        (() => {
          const host = document.querySelector('diffs-container');
          const root = host?.shadowRoot;
          return {
            lines: root?.querySelectorAll('[data-line]').length ?? 0,
            tokens: root?.querySelectorAll('[data-line] span').length ?? 0,
            lineHeight: getComputedStyle(host).getPropertyValue('--diffs-line-height').trim(),
            networkScripts: [...document.scripts].filter(script => /^https?:/.test(script.src)).length,
            bodyMargin: getComputedStyle(document.body).margin,
            rowHeight: root?.querySelector('[data-line]')?.getBoundingClientRect().height ?? 0,
            addition: getComputedStyle(host).getPropertyValue('--diffs-bg-addition-override').trim(),
            deletion: getComputedStyle(host).getPropertyValue('--diffs-bg-deletion-override').trim()
          };
        })()
        """)
        let values = try #require(result as? [String: Any])
        #expect((values["lines"] as? Int ?? 0) > 0)
        #expect((values["tokens"] as? Int ?? 0) > 0)
        #expect(values["lineHeight"] as? String == "1.85")
        #expect(values["networkScripts"] as? Int == 0)
        #expect(values["bodyMargin"] as? String == "0px", "The bundled stylesheet must load under the document CSP")
        #expect((values["rowHeight"] as? Double ?? 0) >= 20)
        #expect(values["addition"] as? String == "rgba(46, 160, 67, 0.30)")
        #expect(values["deletion"] as? String == "rgba(248, 81, 73, 0.30)")
    }

    @Test("Select All reaches code inside WebKit's shadow tree") @MainActor
    func selectAllEnablesAsk() async throws {
        let mounted = mount(file: PRReviewDemo.diff().files[0])
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)
        let selected = try await mounted.view.evaluateJavaScript("""
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
        window.getSelection().toString();
        """) as? String
        #expect(selected?.contains("struct SeedCatalog {}") == true)
        #expect(selected?.contains("--diffs-") == false, "Select code, not the shadow stylesheet")
        var showsAsk = false
        for _ in 0..<50 {
            showsAsk = (try await mounted.view.evaluateJavaScript("document.querySelector('.native-ask') !== null")) as? Bool ?? false
            if showsAsk { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(showsAsk, "A real shadow-tree selection must expose the Ask action")
    }

    @Test("Long lines retain horizontal overflow") @MainActor
    func longLinesScrollHorizontally() async throws {
        var file = PRReviewDemo.diff().files[0]
        file.hunks[0].lines[0].text = String(repeating: "syntheticGardenValue", count: 80)
        let mounted = mount(file: file, size: CGSize(width: 500, height: 260))
        defer { mounted.window.close() }
        _ = await waitUntil { mounted.view.renderedIdentity != nil }

        let scrolls = try await mounted.view.evaluateJavaScript("""
        (() => {
          const root = document.querySelector('diffs-container').shadowRoot;
          const scroll = [...root.querySelectorAll('*')].find(element =>
            element.scrollWidth > element.clientWidth &&
            ['auto', 'scroll'].includes(getComputedStyle(element).overflowX));
          if (!scroll) return false;
          scroll.scrollLeft = scroll.scrollWidth;
          return scroll.scrollLeft > 0;
        })()
        """) as? Bool
        #expect(scrolls == true, "Long code must be horizontally reachable inside the shared renderer")
    }

    @Test("A scroll requested before page readiness reaches the requested hunk") @MainActor
    func queuesInitialScroll() async throws {
        var file = PRReviewDemo.diff().files[0]
        file.hunks = [file.hunks[0]]
        file.hunks[0].lines = (1...100).map {
            PRReviewDiffLine(kind: "context", oldNumber: $0, newNumber: $0, text: "let seed\($0) = \($0)")
        }
        let mounted = mount(file: file, size: CGSize(width: 700, height: 220))
        defer { mounted.view.tearDown(); mounted.window.close() }
        mounted.view.scrollToLine(90, side: .after)
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)
        var visible = false
        for _ in 0..<100 {
            visible = (try? await mounted.view.evaluateJavaScript("(() => { const r = document.querySelector('diffs-container').shadowRoot.querySelector('[data-line=\"90\"]').getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })()")) as? Bool ?? false
            if visible { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(visible)
    }

    @MainActor
    private func deletedFixture() -> PRReviewDiffFile {
        var file = PRReviewDemo.diff().files[0]
        file.status = "deleted"
        file.hunks = [
            .init(
                oldStart: 6,
                oldLines: 2,
                newStart: 0,
                newLines: 0,
                header: "@@",
                lines: [
                    .init(kind: "del", oldNumber: 6, newNumber: nil, text: "let obsoleteSeed = 1"),
                    .init(kind: "del", oldNumber: 7, newNumber: nil, text: "let legacySeed = 2"),
                ]
            )
        ]
        return file
    }

    @MainActor
    private func mount(
        file: PRReviewDiffFile,
        size: CGSize = CGSize(width: 760, height: 360),
        highlight: (start: Int, end: Int, side: PRReviewSide)? = nil
    ) -> (window: NSWindow, view: PRReviewDiffTextView) {
        let hosting = NSHostingView(rootView:
            PRReviewDiffText(
                file: file,
                baseSHA: "synthetic-base",
                headSHA: "synthetic-head",
                highlight: highlight
            )
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let view = descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first!
        return (window, view)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
