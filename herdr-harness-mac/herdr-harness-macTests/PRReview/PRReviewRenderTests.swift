import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review renders", .serialized)
struct PRReviewRenderTests {
    @Test("Sidebar renders demo review data")
    func rendersSidebar() async throws {
        let store = demoStore()
        let result = try await HerdrRenderHarness.render(
            "pr-review-sidebar.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewSidebarView(store: store, back: {}, canControl: true)
        }

        result.expectSubstantial()
    }

    @Test("Files tab renders demo review data")
    func rendersFilesContainer() async throws {
        let store = demoStore()
        let result = try await HerdrRenderHarness.render(
            "pr-review-files.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }

        result.expectSubstantial()
    }

    @Test(
        "Files layout bounds the rail and displays native code",
        arguments: [CGFloat(1240), 1720]
    )
    func filesLayoutShowsCode(width: CGFloat) async throws {
        let size = CGSize(width: width, height: width < 1500 ? 820 : 1060)
        let store = demoStore()
        let hosting = NSHostingView(rootView:
            PRReviewContainerView(store: store, canControl: true)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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

        let split = try #require(descendants(hosting).compactMap { $0 as? NSSplitView }.first)
        let rail = try #require(split.subviews.first)
        let textView = try #require(descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first)
        let codeViewport = try #require(textView.enclosingScrollView?.contentView)
        let railRect = rail.convert(rail.bounds, to: hosting)
        let codeViewportRect = codeViewport.convert(codeViewport.bounds, to: hosting)
        let minimumRemainingWidth = size.width - PRReviewFilesLayout.maximumRailWidth - 20

        #expect(railRect.width >= PRReviewFilesLayout.minimumRailWidth - 1)
        #expect(railRect.width <= PRReviewFilesLayout.maximumRailWidth + 1)
        #expect(codeViewportRect.width > railRect.width)
        #expect(codeViewportRect.width >= minimumRemainingWidth)
        #expect(codeViewportRect.minX >= railRect.maxX - 1)
        #expect(codeViewportRect.maxX >= size.width - 20)
        #expect(codeViewportRect.height > size.height * 0.6)
        #expect(split.frame.height > size.height * 0.72)
        #expect(textView.string.contains("struct SeedCatalog {}"))
        #expect(textView.isLineVisible(2, side: .after))
        #expect(textView.enclosingScrollView?.hasVerticalScroller == true)
        #expect(textView.enclosingScrollView?.hasHorizontalScroller == true)
    }

    @Test("Deleted and partial file views keep available code visible")
    func deletedAndPartialFilesShowNativeText() async throws {
        for mode in ["deleted", "partial"] {
            let store = PRReviewStore()
            store.configure(client: nil, machineID: "synthetic-host", demo: false)
            store.select(PRReviewDemo.reviewID)
            var snapshot = PRReviewDemo.snapshot()
            var diff = PRReviewDemo.diff()
            if mode == "deleted" {
                snapshot.files[0].status = "deleted"
                diff.files[0].status = "deleted"
                diff.files[0].hunks = [diff.files[0].hunks[1]]
            } else {
                diff.truncated = true
                diff.files[0].truncated = true
            }
            store.receive(snapshot)
            store.selectedPath = snapshot.files[0].path
            store.diff = diff

            let size = CGSize(width: 980, height: 620)
            let hosting = NSHostingView(rootView:
                PRReviewDiffView(store: store)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .dark)
            )
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
            #expect(!textView.string.isEmpty, "\(mode) review should keep available code visible")
            if mode == "deleted" {
                #expect(textView.string.contains("-old"))
            } else {
                #expect(textView.string.contains("struct SeedCatalog {}"))
            }
        }
    }

    @Test("Preparing, failure, empty, filtered, and ready states stay distinct")
    func resolvesFilesPresentationStates() {
        #expect(PRReviewFilesPresentation.resolve(
            status: .preparing, reviewError: nil, hasSnapshot: false, fileCount: 0, visibleFileCount: 0
        ) == .preparing)
        #expect(PRReviewFilesPresentation.resolve(
            status: .failed, reviewError: "Synthetic checkout failure", hasSnapshot: true, fileCount: 0, visibleFileCount: 0
        ) == .failed("Synthetic checkout failure"))
        #expect(PRReviewFilesPresentation.resolve(
            status: .ready, reviewError: nil, hasSnapshot: false, fileCount: 0, visibleFileCount: 0
        ) == .loading)
        #expect(PRReviewFilesPresentation.resolve(
            status: .ready, reviewError: nil, hasSnapshot: true, fileCount: 0, visibleFileCount: 0
        ) == .noFiles)
        #expect(PRReviewFilesPresentation.resolve(
            status: .ready, reviewError: nil, hasSnapshot: true, fileCount: 2, visibleFileCount: 0
        ) == .noFilterMatches)
        #expect(PRReviewFilesPresentation.resolve(
            status: .ready, reviewError: nil, hasSnapshot: true, fileCount: 2, visibleFileCount: 1
        ) == .content)
    }

    @Test("Blank review titles fall back to a useful pull request label")
    func blankReviewTitleFallback() {
        var review = PRReviewDemo.snapshot().review
        review.title = "  "
        #expect(PRReviewHeaderText.title(for: review) == "example-owner/garden-planner #42")
        review.owner = ""
        review.repo = ""
        #expect(PRReviewHeaderText.title(for: review) == "Pull request #42")
    }

    @Test("A ready review selects its first visible file")
    func readyReviewSelectsVisibleFile() async throws {
        let store = demoStore()
        store.selectedPath = nil
        let size = CGSize(width: 980, height: 620)
        let hosting = NSHostingView(rootView: PRReviewFilesView(store: store).frame(width: size.width, height: size.height))
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
        #expect(store.selectedPath == store.orderedFiles.first?.path)
    }

    @Test("Context tab renders demo review data")
    func rendersContextContainer() async throws {
        let store = demoStore()
        store.tab = .context
        let result = try await HerdrRenderHarness.render(
            "pr-review-context.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Agents tab renders demo review data")
    func rendersAgentsContainer() async throws {
        let store = demoStore()
        store.tab = .agents
        let result = try await HerdrRenderHarness.render(
            "pr-review-agents.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Skills tab renders demo review data")
    func rendersSkillsContainer() async throws {
        let store = demoStore()
        store.tab = .skills
        let result = try await HerdrRenderHarness.render(
            "pr-review-skills.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Diff renders a highlighted review range")
    func rendersHighlightedDiff() async throws {
        let file = PRReviewDemo.diff().files[0]
        let result = try await HerdrRenderHarness.render(
            "pr-review-highlight.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file, highlight: (start: 2, end: 2, side: .after))
        }

        result.expectSubstantial()
    }

    @Test("Large text scale changes the diff render")
    func rendersLargeTextScaleDifferently() async throws {
        let file = PRReviewDemo.diff().files[0]
        let defaultResult = try await HerdrRenderHarness.render(
            "pr-review-diff-default.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file)
        }
        let largeResult = try await HerdrRenderHarness.render(
            "pr-review-diff-xxlarge.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file)
                .environment(\.herdrFontScale, .xxLarge)
        }

        defaultResult.expectSubstantial()
        largeResult.expectSubstantial()
        #expect(defaultResult.byteCount != largeResult.byteCount)
    }

    private func demoStore() -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path
        store.diff = PRReviewDemo.diff()
        return store
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
