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

    @Test("Add comment appears only when a host callback exists") @MainActor
    func addCommentRequiresHostCallback() async throws {
        var received: [PRReviewSelection] = []
        let mounted = mount(file: commentingFixture())
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)

        _ = try await selectDiff(mounted.view, from: contextSelector, to: contextSelector)
        var askShown = await waitForSelector(mounted.view, ".native-ask")
        try #require(askShown)
        var commentShown = await waitForSelector(mounted.view, ".native-comment")
        #expect(!commentShown, "Without a callback the comment action must stay hidden")

        mounted.view.addComment = { received.append($0) }
        commentShown = await waitForSelector(mounted.view, ".native-comment")
        try #require(commentShown)
        let button = try await mounted.view.evaluateJavaScript("""
        (() => {
          const element = document.querySelector('.native-comment');
          return { tag: element?.tagName, text: element?.textContent, type: element?.getAttribute('type') };
        })()
        """) as? [String: Any]
        #expect(button?["tag"] as? String == "BUTTON")
        #expect(button?["type"] as? String == "button")
        #expect((button?["text"] as? String)?.contains("Add comment") == true)

        mounted.view.addComment = nil
        commentShown = await waitForSelector(mounted.view, ".native-comment", exists: false)
        #expect(!commentShown, "Removing the callback must hide the comment action")
        askShown = await waitForSelector(mounted.view, ".native-ask")
        #expect(askShown, "Ask AI keeps working independently of commenting")
        #expect(received.isEmpty)
    }

    @Test("Add comment delivers the exact mixed-side selection without asking AI") @MainActor
    func addCommentDeliversSelection() async throws {
        var received: [PRReviewSelection] = []
        var askedCount = 0
        let mounted = mount(
            file: commentingFixture(),
            askAI: { _, _, _ in askedCount += 1 },
            addComment: { received.append($0) }
        )
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)

        let selected = try await selectDiff(
            mounted.view,
            from: contextSelector,
            to: additionSelector
        )
        #expect(selected.contains("let seed = '🌻'"))
        #expect(selected.contains("\tlet added = 3  "))
        let commentShown = await waitForSelector(mounted.view, ".native-comment")
        try #require(commentShown)
        let clicked = try await clickComment(mounted.view)
        try #require(clicked)
        let delivered = await waitUntil { !received.isEmpty }
        try #require(delivered)

        let comment = try #require(received.first)
        #expect(comment.path == "Sources/Catalog/SeedCatalog.swift")
        #expect(comment.oldPath == "")
        #expect(comment.spans == [
            .init(side: .after, start: 1, end: 1),
            .init(side: .before, start: 2, end: 2),
            .init(side: .after, start: 2, end: 3),
        ])
        #expect(comment.text == "  let seed = '🌻'\n  let removed = 2\n\n\tlet added = 3  ")
        #expect(comment.question == nil)
        #expect(askedCount == 0)
        #expect(mounted.view.askPopover == nil, "A comment must not open the Ask AI popover")
    }

    @Test("Removed, added and context rows keep their own side and line") @MainActor
    func addCommentMapsSelectionSides() async throws {
        var received: [PRReviewSelection] = []
        let mounted = mount(file: commentingFixture(), addComment: { received.append($0) })
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)

        let cases: [(selector: String, text: String, span: PRReviewSelection.Span)] = [
            ("[data-line-type=change-deletion], [data-line-type=deletion]", "  let removed = 2",
             .init(side: .before, start: 2, end: 2)),
            ("[data-line-type=change-addition], [data-line-type=addition]", "\tlet added = 3  ",
             .init(side: .after, start: 3, end: 3)),
            ("[data-line-type=context]", "  let seed = '🌻'", .init(side: .after, start: 1, end: 1)),
        ]
        for expected in cases {
            received.removeAll()
            let selected = try await selectDiff(mounted.view, from: expected.selector, to: expected.selector)
            #expect(selected == expected.text)
            let commentShown = await waitForSelector(mounted.view, ".native-comment")
            try #require(commentShown)
            let clicked = try await clickComment(mounted.view)
            try #require(clicked)
            let delivered = await waitUntil { received.count == 1 }
            try #require(delivered)
            let comment = try #require(received.first)
            #expect(comment.spans == [expected.span])
            #expect(comment.text == expected.text)
            let cleared = await waitForSelector(mounted.view, ".native-selection-actions", exists: false)
            try #require(cleared)
        }
    }

    @Test("Stale comment messages never reach the host callback") @MainActor
    func staleCommentMessagesAreRejected() async throws {
        var received: [PRReviewSelection] = []
        let file = commentingFixture()
        let mounted = mount(file: file, addComment: { received.append($0) })
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)
        let identityValue = try await mounted.view.evaluateJavaScript("document.querySelector('main')?.dataset.renderIdentity")
        let identity = try #require(identityValue as? String)

        _ = try await mounted.view.evaluateJavaScript("""
        (() => {
          window.__staleRenderIdentity = document.querySelector('main').dataset.renderIdentity;
          const handler = window.webkit.messageHandlers.herdrDiffBridge;
          handler.postMessage({ kind: 'comment', identity: 'stale-fictional-identity', path: '\(file.path)', oldPath: '',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'stale identity' });
          handler.postMessage({ kind: 'comment', identity: window.__staleRenderIdentity, path: 'Sources/Other.swift', oldPath: '',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'wrong path' });
          handler.postMessage({ kind: 'comment', identity: window.__staleRenderIdentity, path: '\(file.path)', oldPath: 'Sources/Old.swift',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'wrong old path' });
          handler.postMessage({ kind: 'comment', identity: window.__staleRenderIdentity, path: '\(file.path)', oldPath: '',
            spans: [{ side: 'sideways', startLine: 2, endLine: 2 }], exactCode: 'wrong side' });
          handler.postMessage({ kind: 'comment', identity: window.__staleRenderIdentity, path: '\(file.path)', oldPath: '',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'sentinel selection' });
          return true;
        })()
        """)
        var delivered = await waitUntil { received.count == 1 }
        try #require(delivered)
        #expect(received.first?.text == "sentinel selection")
        try await Task.sleep(for: .milliseconds(120))
        #expect(received.count == 1, "Malformed or stale messages must be dropped")

        // A revision change invalidates every earlier render identity.
        mounted.view.render(PRReviewDiffRenderer.payload(file: file, identity: "fictional-next-revision"))
        var identityChanged = false
        for _ in 0..<100 {
            let current = try? await mounted.view.evaluateJavaScript("document.querySelector('main')?.dataset.renderIdentity") as? String
            if let current, current != identity { identityChanged = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(identityChanged)
        _ = try await mounted.view.evaluateJavaScript("""
        (() => {
          const handler = window.webkit.messageHandlers.herdrDiffBridge;
          handler.postMessage({ kind: 'comment', identity: window.__staleRenderIdentity, path: '\(file.path)', oldPath: '',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'revision-stale selection' });
          handler.postMessage({ kind: 'comment', identity: document.querySelector('main').dataset.renderIdentity,
            path: '\(file.path)', oldPath: '',
            spans: [{ side: 'old', startLine: 2, endLine: 2 }], exactCode: 'fresh revision selection' });
          return true;
        })()
        """)
        delivered = await waitUntil { received.count == 2 }
        try #require(delivered)
        #expect(received.last?.text == "fresh revision selection")
    }

    @Test("Selection controls stay inside a narrow enlarged viewport") @MainActor
    func selectionControlsFitNarrowViewport() async throws {
        let mounted = mount(file: commentingFixture(), size: CGSize(width: 300, height: 320),
                            addComment: { _ in })
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)
        mounted.view.pageZoom = 1.5
        // Let the zoom-driven layout and resize settle before measuring.
        try await Task.sleep(for: .milliseconds(200))

        _ = try await selectDiff(mounted.view, from: contextSelector, to: contextSelector)
        let commentShown = await waitForSelector(mounted.view, ".native-comment")
        try #require(commentShown)
        let geometry = try await mounted.view.evaluateJavaScript("""
        (() => {
          const container = document.querySelector('.native-selection-actions');
          if (!container) return null;
          const containerRect = container.getBoundingClientRect();
          const buttons = [...container.querySelectorAll('.native-ask, .native-comment')];
          const rows = buttons.map(button => button.getBoundingClientRect());
          return {
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            left: containerRect.left,
            right: containerRect.right,
            top: containerRect.top,
            bottom: containerRect.bottom,
            minLeft: Math.min(...rows.map(rect => rect.left)),
            maxRight: Math.max(...rows.map(rect => rect.right))
          };
        })()
        """) as? [String: Any]
        let values = try #require(geometry)
        let viewportWidth = values["viewportWidth"] as? Double ?? 0
        let viewportHeight = values["viewportHeight"] as? Double ?? 0
        #expect((values["left"] as? Double ?? -1) >= 0)
        #expect((values["right"] as? Double ?? .infinity) <= viewportWidth)
        #expect((values["minLeft"] as? Double ?? -1) >= 0)
        #expect((values["maxRight"] as? Double ?? .infinity) <= viewportWidth)
        #expect((values["top"] as? Double ?? -1) >= 0)
        #expect((values["bottom"] as? Double ?? .infinity) <= viewportHeight)
    }

    @Test("Right-click keeps the Ask AI path") @MainActor
    func rightClickKeepsAskPath() async throws {
        var received: [PRReviewSelection] = []
        let mounted = mount(file: commentingFixture(), addComment: { received.append($0) })
        defer { mounted.view.tearDown(); mounted.window.close() }
        let ready = await waitUntil { mounted.view.renderedIdentity != nil }
        try #require(ready)
        _ = try await selectDiff(mounted.view, from: additionSelector, to: additionSelector)
        let commentShown = await waitForSelector(mounted.view, ".native-comment")
        try #require(commentShown)

        let dispatched = try await mounted.view.evaluateJavaScript("""
        (() => {
          const element = document.querySelector('diffs-container').shadowRoot.querySelector('\(additionSelector)');
          if (!element) return false;
          const rect = element.getBoundingClientRect();
          element.dispatchEvent(new MouseEvent('contextmenu', {
            bubbles: true, composed: true, clientX: rect.left + 4, clientY: rect.top + 4
          }));
          return true;
        })()
        """) as? Bool
        #expect(dispatched == true)
        var popoverShown = false
        for _ in 0..<100 {
            popoverShown = mounted.view.askPopover != nil
            if popoverShown { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(popoverShown, "Right-click must still open the Ask AI popover")
        try await Task.sleep(for: .milliseconds(120))
        #expect(received.isEmpty, "Right-click must not deliver a local comment")
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
    private func mount(
        file: PRReviewDiffFile,
        size: CGSize = CGSize(width: 760, height: 360),
        askAI: ((PRReviewSelection, NSView, CGRect) -> Void)? = nil,
        addComment: ((PRReviewSelection) -> Void)? = nil
    ) -> (window: NSWindow, view: PRReviewDiffTextView) {
        let hosting = NSHostingView(rootView:
            PRReviewDiffText(file: file, baseSHA: "synthetic-base", headSHA: "synthetic-head",
                             askAI: askAI, addComment: addComment)
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

    private let contextSelector = "[data-line-type=context]"
    private let additionSelector = "[data-line-type=change-addition], [data-line-type=addition]"

    /// A synthetic one-hunk file with exact whitespace, Unicode and a blank
    /// context line, plus distinct added, removed and context rows.
    private func commentingFixture() -> PRReviewDiffFile {
        PRReviewDiffFile(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: nil,
            status: "modified",
            additions: 1,
            deletions: 1,
            binary: false,
            truncated: false,
            hunks: [
                PRReviewDiffHunk(
                    oldStart: 1, oldLines: 4, newStart: 1, newLines: 4,
                    header: "@@",
                    lines: [
                        PRReviewDiffLine(kind: "context", oldNumber: 1, newNumber: 1, text: "  let seed = '🌻'"),
                        PRReviewDiffLine(kind: "del", oldNumber: 2, newNumber: nil, text: "  let removed = 2"),
                        PRReviewDiffLine(kind: "context", oldNumber: 3, newNumber: 2, text: ""),
                        PRReviewDiffLine(kind: "add", oldNumber: nil, newNumber: 3, text: "\tlet added = 3  "),
                        PRReviewDiffLine(kind: "context", oldNumber: 4, newNumber: 4, text: "return seed"),
                    ]
                )
            ]
        )
    }

    /// Selects rendered diff elements inside Pierre's shadow root, mirroring
    /// a real drag selection, and returns the selected text.
    @MainActor
    private func selectDiff(_ view: PRReviewDiffTextView, from: String, to: String) async throws -> String {
        let selected = try await view.evaluateJavaScript("""
        (() => {
          const root = document.querySelector('diffs-container').shadowRoot;
          const first = root?.querySelector('\(from)');
          const last = root?.querySelector('\(to)');
          if (!first || !last) return '';
          const selection = window.getSelection();
          selection.setBaseAndExtent(first, 0, last, last.childNodes.length);
          document.dispatchEvent(new Event('selectionchange'));
          document.dispatchEvent(new Event('pointerup'));
          return selection.toString();
        })()
        """)
        return selected as? String ?? ""
    }

    @MainActor
    private func clickComment(_ view: PRReviewDiffTextView) async throws -> Bool {
        let clicked = try await view.evaluateJavaScript("""
        (() => {
          const button = document.querySelector('.native-comment');
          if (!button) return false;
          button.click();
          return true;
        })()
        """) as? Bool
        return clicked == true
    }

    @MainActor
    private func waitForSelector(_ view: PRReviewDiffTextView, _ selector: String, exists: Bool = true) async -> Bool {
        for _ in 0..<100 {
            let found = (try? await view.evaluateJavaScript("document.querySelector('\(selector)') !== null")) as? Bool ?? false
            if found == exists { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let found = (try? await view.evaluateJavaScript("document.querySelector('\(selector)') !== null")) as? Bool ?? false
        return found == exists
    }
}
