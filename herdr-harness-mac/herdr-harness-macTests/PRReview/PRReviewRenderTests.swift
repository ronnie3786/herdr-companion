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

    @Test("Completed missing diff renders for visual review")
    func rendersCompletedMissingDiff() async throws {
        let configuration = try #require(ServerConfiguration(
            urlString: "https://example.invalid",
            token: "synthetic-token"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewMissingDiffURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let store = PRReviewStore()
        let snapshot = PRReviewDemo.snapshot()
        let selectedPath = snapshot.files[0].path
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(snapshot.review.id)
        store.receive(snapshot)
        store.selectedPath = selectedPath
        await store.loadDiff(for: selectedPath)

        #expect(store.completedDiffIdentity == store.currentDiffRequestIdentity)
        #expect(store.diff?.files.isEmpty == true)
        let result = try await HerdrRenderHarness.render(
            "pr-review-completed-missing-diff.png",
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

    // MARK: - Popped-out windows

    @Test("Popped-out review window renders at its default and minimum sizes")
    func rendersPoppedOutWindowSizes() async throws {
        let environment = try poppedOutEnvironment()
        let target = PRReviewWindowTarget(machineID: "demo", reviewID: PRReviewDemo.reviewID)

        let defaultSize = try await HerdrRenderHarness.render(
            "pr-review-window-default.png",
            size: CGSize(width: 1180, height: 820),
            settlePasses: 12
        ) {
            PRReviewWindowRoot(model: environment.model, shell: environment.shell, target: target)
        }
        let minimumSize = try await HerdrRenderHarness.render(
            "pr-review-window-minimum.png",
            size: CGSize(width: 720, height: 520),
            settlePasses: 12
        ) {
            PRReviewWindowRoot(model: environment.model, shell: environment.shell, target: target)
        }

        defaultSize.expectSubstantial()
        minimumSize.expectSubstantial()
    }

    @Test(
        "Popped-out review window keeps its rail, diff, and controls usable",
        arguments: [CGSize(width: 1180, height: 820), CGSize(width: 720, height: 520)]
    )
    func poppedOutWindowSizing(size: CGSize) async throws {
        let environment = try poppedOutEnvironment()
        let target = PRReviewWindowTarget(machineID: "demo", reviewID: PRReviewDemo.reviewID)

        let hosting = NSHostingView(rootView:
            PRReviewWindowRoot(model: environment.model, shell: environment.shell, target: target)
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

        let loaded = await waitForDiffTextView(in: hosting, window: window)
        let textView = try #require(loaded, "The popped-out window should render its native diff")

        let split = try #require(descendants(hosting).compactMap { $0 as? NSSplitView }.first)
        let rail = try #require(split.subviews.first)
        let scrollView = try #require(textView.enclosingScrollView)
        let codeViewport = try #require(scrollView.contentView)
        let railRect = rail.convert(rail.bounds, to: hosting)
        let codeColumnRect = scrollView.convert(scrollView.bounds, to: hosting)
        let codeViewportRect = codeViewport.convert(codeViewport.bounds, to: hosting)

        #expect(railRect.width >= PRReviewFilesLayout.minimumRailWidth - 1)
        #expect(railRect.width <= PRReviewFilesLayout.maximumRailWidth + 1)
        #expect(codeColumnRect.width >= PRReviewFilesLayout.minimumDiffWidth - 1)
        #expect(codeColumnRect.maxX >= size.width - 20)
        #expect(codeViewportRect.minX >= railRect.maxX - 1)
        #expect(codeViewportRect.width > railRect.width * 0.5)
        #expect(codeViewportRect.height > size.height * 0.5)
        #expect(split.frame.height > size.height * 0.55)
        #expect(textView.string.contains("struct SeedCatalog {}"))
        #expect(textView.isLineVisible(2, side: .after))
        #expect(textView.enclosingScrollView?.hasVerticalScroller == true)
        #expect(textView.enclosingScrollView?.hasHorizontalScroller == true)

        let segmentedControls = descendants(hosting).compactMap { $0 as? NSSegmentedControl }
        #expect(
            segmentedControls.contains { $0.isEnabled },
            "The popped-out review should keep its tab picker usable"
        )
    }

    @Test(
        "Change rows, gutters, and emphasis stay visible at default and enlarged scales",
        arguments: [HerdrFontScale.default, HerdrFontScale.xxLarge]
    )
    func changeTreatmentIsVisible(fontScale: HerdrFontScale) async throws {
        let render = try await mountDiff(
            PRReviewDiffFile(
                path: "Sources/Garden/Planting.swift",
                oldPath: nil,
                status: "modified",
                additions: 1,
                deletions: 1,
                binary: false,
                truncated: false,
                hunks: [
                    PRReviewDiffHunk(
                        oldStart: 1,
                        oldLines: 3,
                        newStart: 1,
                        newLines: 3,
                        header: "@@ -1,3 +1,3 @@",
                        lines: [
                            PRReviewDiffLine(kind: "context", oldNumber: 1, newNumber: 1, text: "import Foundation"),
                            PRReviewDiffLine(kind: "del", oldNumber: 2, newNumber: nil, text: "let seed = oldValue"),
                            PRReviewDiffLine(kind: "add", oldNumber: nil, newNumber: 2, text: "let seed = newValue"),
                            PRReviewDiffLine(kind: "context", oldNumber: 3, newNumber: 3, text: "print(\"done\")"),
                        ]
                    )
                ]
            ),
            fontScale: fontScale
        )
        defer { render.window.close() }

        let addEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "add" })
        let delEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "del" })
        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let addLine = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let delLine = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let addGutter = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.gutterOpacity, over: addLine)
        let delGutter = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.gutterOpacity, over: delLine)
        let addEmphasis = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.emphasisOpacity, over: addLine)
        let delEmphasis = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.emphasisOpacity, over: delLine)

        let rightEdge = render.textView.bounds.width - 3
        expect(
            try sample(CGPoint(x: rightEdge, y: fragmentRect(for: addEntry, in: render).midY), in: render),
            matches: addLine,
            tolerance: 0.05
        )
        expect(
            try sample(CGPoint(x: rightEdge, y: fragmentRect(for: delEntry, in: render).midY), in: render),
            matches: delLine,
            tolerance: 0.05
        )
        expect(
            try closestPixel(in: gutterRect(for: addEntry, in: render), to: addGutter, in: render).color,
            matches: addGutter,
            tolerance: 0.05
        )
        expect(
            try closestPixel(in: gutterRect(for: delEntry, in: render), to: delGutter, in: render).color,
            matches: delGutter,
            tolerance: 0.05
        )

        let storage = try #require(render.textView.textStorage)
        let emphasisRanges = backgroundRanges(in: storage)
        let addEmphasisRange = try #require(emphasisRanges.first {
            NSLocationInRange($0.location, entryRange(addEntry))
        })
        let delEmphasisRange = try #require(emphasisRanges.first {
            NSLocationInRange($0.location, entryRange(delEntry))
        })
        expect(
            try closestPixel(in: enclosingRect(for: addEmphasisRange, in: render), to: addEmphasis, in: render).color,
            matches: addEmphasis,
            tolerance: 0.05
        )
        expect(
            try closestPixel(in: enclosingRect(for: delEmphasisRange, in: render), to: delEmphasis, in: render).color,
            matches: delEmphasis,
            tolerance: 0.05
        )
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

    // MARK: - Popped-out window helpers

    private func poppedOutEnvironment() throws -> (model: HerdrAppModel, shell: HerdrShellState) {
        let defaults = try #require(UserDefaults(suiteName: "PRReviewRenderTests.\(UUID().uuidString)"))
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: defaults,
            configuredMachines: []
        )
        return (model, HerdrShellState(userDefaults: defaults))
    }

    private func waitForDiffTextView(in hosting: NSView, window: NSWindow) async -> PRReviewDiffTextView? {
        for _ in 0..<60 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
            if let textView = descendants(hosting).compactMap({ $0 as? PRReviewDiffTextView }).first,
               !textView.string.isEmpty {
                if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
                    layoutManager.ensureLayout(for: textContainer)
                }
                return textView
            }
        }
        return nil
    }
}

// MARK: - Rendered diff pixels

/// Mounts the native diff offscreen and samples what it actually painted.
/// `PRReviewDiffStyleTests` owns the exhaustive treatment matrix; these helpers
/// exist so the render suite can also prove the treatment survives the default
/// and enlarged text scales and the popped-out window's own store.
private struct MountedDiffRender {
    let window: NSWindow
    let textView: PRReviewDiffTextView
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let bitmap: NSBitmapImageRep
    let scale: CGFloat
}

@MainActor
extension PRReviewRenderTests {
    fileprivate func mountDiff(
        _ file: PRReviewDiffFile,
        fontScale: HerdrFontScale,
        size: CGSize = CGSize(width: 820, height: 300)
    ) async throws -> MountedDiffRender {
        let hosting = NSHostingView(rootView:
            PRReviewDiffText(file: file)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.herdrFontScale, fontScale)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()

        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }

        let textView = try #require(descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first)
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(textView.bounds.width * scale))),
            pixelsHigh: max(1, Int(ceil(textView.bounds.height * scale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = textView.bounds.size
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        return MountedDiffRender(
            window: window,
            textView: textView,
            layoutManager: layoutManager,
            textContainer: textContainer,
            bitmap: bitmap,
            scale: scale
        )
    }

    fileprivate func entryRange(_ entry: PRReviewLineIndex.Entry) -> NSRange {
        NSRange(location: entry.utf16Offset, length: entry.length)
    }

    fileprivate func fragmentRect(for entry: PRReviewLineIndex.Entry, in render: MountedDiffRender) -> NSRect {
        let glyphs = render.layoutManager.glyphRange(forCharacterRange: entryRange(entry), actualCharacterRange: nil)
        let used = render.layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return used.offsetBy(
            dx: render.textView.textContainerOrigin.x,
            dy: render.textView.textContainerOrigin.y
        )
    }

    fileprivate func gutterRect(for entry: PRReviewLineIndex.Entry, in render: MountedDiffRender) -> NSRect {
        enclosingRect(
            for: NSRange(location: entry.utf16Offset, length: entry.gutterLength),
            in: render
        )
    }

    fileprivate func enclosingRect(for range: NSRange, in render: MountedDiffRender) -> NSRect {
        let glyphs = render.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var union = NSRect.null
        render.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: render.textContainer
        ) { rect, _ in
            union = union.union(rect)
        }
        return union.offsetBy(
            dx: render.textView.textContainerOrigin.x,
            dy: render.textView.textContainerOrigin.y
        )
    }

    fileprivate func sample(
        _ point: CGPoint,
        in render: MountedDiffRender
    ) throws -> (red: Double, green: Double, blue: Double) {
        let bounds = render.textView.bounds
        let viewY = render.textView.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        let pixelX = Int(((point.x - bounds.minX) * render.scale).rounded())
        let pixelY = Int((viewY * render.scale).rounded())
        return try resolve(pixelX: pixelX, pixelY: pixelY, in: render)
    }

    fileprivate func closestPixel(
        in rect: NSRect,
        to expected: (red: Double, green: Double, blue: Double),
        in render: MountedDiffRender
    ) throws -> (color: (red: Double, green: Double, blue: Double), distance: Double) {
        let bounds = render.textView.bounds
        let top = render.textView.isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        let bottom = render.textView.isFlipped ? rect.maxY - bounds.minY : bounds.maxY - rect.minY
        let minX = max(0, Int(((rect.minX - bounds.minX) * render.scale).rounded(.down)))
        let maxX = min(render.bitmap.pixelsWide - 1, Int(((rect.maxX - bounds.minX) * render.scale).rounded(.up)))
        let minY = max(0, Int((top * render.scale).rounded(.down)))
        let maxY = min(render.bitmap.pixelsHigh - 1, Int((bottom * render.scale).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { throw DiffSampleError.emptyRect }

        var best: ((red: Double, green: Double, blue: Double), Double)?
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = render.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let sample = (
                    red: Double(color.redComponent),
                    green: Double(color.greenComponent),
                    blue: Double(color.blueComponent)
                )
                let distance = channelDistance(sample, expected)
                if best == nil || distance < best!.1 {
                    best = (sample, distance)
                }
            }
        }
        return try #require(best)
    }

    fileprivate func backgroundRanges(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    fileprivate func expect(
        _ sample: (red: Double, green: Double, blue: Double),
        matches expected: (red: Double, green: Double, blue: Double),
        tolerance: Double = 0.02,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(sample.red - expected.red) < tolerance,
            "red \(sample.red) differs from \(expected.red)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(sample.green - expected.green) < tolerance,
            "green \(sample.green) differs from \(expected.green)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(sample.blue - expected.blue) < tolerance,
            "blue \(sample.blue) differs from \(expected.blue)",
            sourceLocation: sourceLocation
        )
    }

    fileprivate func composite(
        _ color: HerdrDiffStyle.ChangeColor,
        opacity: Double,
        over base: (red: Double, green: Double, blue: Double)
    ) -> (red: Double, green: Double, blue: Double) {
        (
            opacity * Double(color.red) / 255 + (1 - opacity) * base.red,
            opacity * Double(color.green) / 255 + (1 - opacity) * base.green,
            opacity * Double(color.blue) / 255 + (1 - opacity) * base.blue
        )
    }

    private func resolve(
        pixelX: Int,
        pixelY: Int,
        in render: MountedDiffRender
    ) throws -> (red: Double, green: Double, blue: Double) {
        let x = min(max(pixelX, 0), render.bitmap.pixelsWide - 1)
        let y = min(max(pixelY, 0), render.bitmap.pixelsHigh - 1)
        let color = try #require(render.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }

    private func channelDistance(
        _ lhs: (red: Double, green: Double, blue: Double),
        _ rhs: (red: Double, green: Double, blue: Double)
    ) -> Double {
        max(
            abs(lhs.red - rhs.red),
            abs(lhs.green - rhs.green),
            abs(lhs.blue - rhs.blue)
        )
    }
}

private enum DiffSampleError: Error {
    case emptyRect
}

private final class PRReviewMissingDiffURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data("""
        {"ok":true,"review_id":"prr_demo42","base_sha":"base","head_sha":"head","truncated":false,"files":[]}
        """.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
