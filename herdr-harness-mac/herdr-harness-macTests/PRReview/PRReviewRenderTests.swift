import AppKit
import SwiftUI
import Testing
import WebKit
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
        let railRect = rail.convert(rail.bounds, to: hosting)
        let codeViewportRect = textView.convert(textView.bounds, to: hosting)
        let minimumRemainingWidth = size.width - PRReviewFilesLayout.maximumRailWidth - 20

        #expect(railRect.width >= PRReviewFilesLayout.minimumRailWidth - 1)
        #expect(railRect.width <= PRReviewFilesLayout.maximumRailWidth + 1)
        #expect(codeViewportRect.width > railRect.width)
        #expect(codeViewportRect.width >= minimumRemainingWidth)
        #expect(codeViewportRect.minX >= railRect.maxX - 1)
        #expect(codeViewportRect.maxX >= size.width - 20)
        #expect(codeViewportRect.height > size.height * 0.6)
        #expect(split.frame.height > size.height * 0.72)
        #expect(textView.renderedPlainText.contains("struct SeedCatalog {}"))
    }

    @Test("Deleted files stay collapsed until disclosed and partial diffs keep their code")
    func deletedAndPartialFilesShowNativeText() async throws {
        let size = CGSize(width: 980, height: 620)

        let deletedStore = PRReviewStore()
        deletedStore.configure(client: nil, machineID: "synthetic-host", demo: false)
        deletedStore.select(PRReviewDemo.reviewID)
        var deletedSnapshot = PRReviewDemo.snapshot()
        var deletedDiff = PRReviewDemo.diff()
        deletedSnapshot.files[0].status = "deleted"
        deletedDiff.files[0].status = "deleted"
        deletedDiff.files[0].hunks = [deletedDiff.files[0].hunks[1]]
        deletedStore.receive(deletedSnapshot)
        deletedStore.selectedPath = deletedSnapshot.files[0].path
        deletedStore.diff = deletedDiff
        #expect(deletedStore.snapshot?.files[0].isDeleted == true)
        #expect(!deletedStore.isDeletedContentExpanded(path: deletedSnapshot.files[0].path))

        let deletedHosting = NSHostingView(rootView:
            PRReviewDiffView(store: deletedStore)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        deletedHosting.frame = CGRect(origin: .zero, size: size)
        let deletedWindow = NSWindow(contentRect: deletedHosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        deletedWindow.isReleasedWhenClosed = false
        deletedWindow.contentView = deletedHosting
        deletedWindow.alphaValue = 0
        deletedWindow.orderFrontRegardless()
        defer { deletedWindow.close() }

        for _ in 0..<8 {
            deletedHosting.layoutSubtreeIfNeeded()
            deletedWindow.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(
            descendants(deletedHosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
            "A selected deleted file must not show all removed lines before disclosure"
        )

        deletedStore.setDeletedContentExpanded(true, path: deletedSnapshot.files[0].path)
        let expandedText = try #require(await waitForDiffTextView(in: deletedHosting, window: deletedWindow))
        #expect(expandedText.renderedPlainText.contains("-old"))

        deletedStore.setDeletedContentExpanded(false, path: deletedSnapshot.files[0].path)
        for _ in 0..<100 {
            deletedHosting.layoutSubtreeIfNeeded()
            deletedWindow.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
            if descendants(deletedHosting).compactMap({ $0 as? PRReviewDiffTextView }).isEmpty { break }
        }
        #expect(
            descendants(deletedHosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
            "Hiding deleted content must remove the mounted code renderer"
        )

        let partialStore = PRReviewStore()
        partialStore.configure(client: nil, machineID: "synthetic-host", demo: false)
        partialStore.select(PRReviewDemo.reviewID)
        let partialSnapshot = PRReviewDemo.snapshot()
        var partialDiff = PRReviewDemo.diff()
        partialDiff.truncated = true
        partialDiff.files[0].truncated = true
        partialStore.receive(partialSnapshot)
        partialStore.selectedPath = partialSnapshot.files[0].path
        partialStore.diff = partialDiff

        let partialHosting = NSHostingView(rootView:
            PRReviewDiffView(store: partialStore)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        partialHosting.frame = CGRect(origin: .zero, size: size)
        let partialWindow = NSWindow(contentRect: partialHosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        partialWindow.isReleasedWhenClosed = false
        partialWindow.contentView = partialHosting
        partialWindow.alphaValue = 0
        partialWindow.orderFrontRegardless()
        defer { partialWindow.close() }

        let partialText = try #require(await waitForDiffTextView(in: partialHosting, window: partialWindow))
        #expect(partialText.renderedPlainText.contains("struct SeedCatalog {}"), "A partial nondeleted file keeps its available code visible without disclosure")
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
        let railRect = rail.convert(rail.bounds, to: hosting)
        let codeColumnRect = textView.convert(textView.bounds, to: hosting)
        let codeViewportRect = codeColumnRect

        #expect(railRect.width >= PRReviewFilesLayout.minimumRailWidth - 1)
        #expect(railRect.width <= PRReviewFilesLayout.maximumRailWidth + 1)
        #expect(codeColumnRect.width >= PRReviewFilesLayout.minimumDiffWidth - 1)
        #expect(codeColumnRect.maxX >= size.width - 20)
        #expect(codeViewportRect.minX >= railRect.maxX - 1)
        #expect(codeViewportRect.width > railRect.width * 0.5)
        #expect(codeViewportRect.height > size.height * 0.5)
        #expect(split.frame.height > size.height * 0.55)
        #expect(textView.renderedPlainText.contains("struct SeedCatalog {}"))

        let segmentedControls = descendants(hosting).compactMap { $0 as? NSSegmentedControl }
        #expect(
            segmentedControls.contains { $0.isEnabled },
            "The popped-out review should keep its tab picker usable"
        )
    }

    @Test(
        "Shared renderer keeps syntax and spacious lines at default and enlarged scales",
        arguments: [HerdrFontScale.default, HerdrFontScale.xxLarge]
    )
    func changeTreatmentIsVisible(fontScale: HerdrFontScale) async throws {
        var file = PRReviewDemo.diff().files[0]
        file.hunks = [file.hunks[0]]
        file.hunks[0].lines = [
            .init(kind: "del", oldNumber: 1, newNumber: nil, text: "let seed = oldSeed"),
            .init(kind: "add", oldNumber: nil, newNumber: 1, text: "let seed = newSeed"),
        ]
        let size = CGSize(width: 820, height: 300)
        let hosting = NSHostingView(rootView:
            PRReviewDiffText(file: file)
                .frame(width: size.width, height: size.height)
                .environment(\.herdrFontScale, fontScale)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }

        let view = try #require(await waitForDiffTextView(in: hosting, window: window))
        for _ in 0..<200 where view.renderedIdentity == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(view.renderedIdentity != nil)
        for _ in 0..<100 {
            let count = (try? await view.evaluateJavaScript("document.querySelector('diffs-container')?.shadowRoot?.querySelectorAll('[data-diff-span]').length ?? 0")) as? Int ?? 0
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const host = document.querySelector('diffs-container');
          return {
            scale: getComputedStyle(host).getPropertyValue('--herdr-diff-font-scale').trim(),
            lineHeight: getComputedStyle(host).getPropertyValue('--diffs-line-height').trim(),
            changed: host?.shadowRoot?.querySelectorAll('[data-line-type$="addition"], [data-line-type$="deletion"]').length ?? 0,
            emphasis: host?.shadowRoot?.querySelectorAll('[data-diff-span]').length ?? 0,
            fontSize: parseFloat(getComputedStyle(host.shadowRoot.querySelector('[data-line]')).fontSize),
            rowHeight: host.shadowRoot.querySelector('[data-line]').getBoundingClientRect().height
          };
        })()
        """)
        let values = try #require(result as? [String: Any])
        #expect(Double(values["scale"] as? String ?? "") == fontScale.rawValue)
        #expect(abs((values["fontSize"] as? Double ?? 0) - 12 * fontScale.rawValue) < 0.1)
        #expect((values["rowHeight"] as? Double ?? 0) >= 20 * fontScale.rawValue)
        #expect(values["lineHeight"] as? String == "1.85")
        #expect((values["changed"] as? Int ?? 0) > 0)
        #expect((values["emphasis"] as? Int ?? 0) > 0)
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
        for _ in 0..<400 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
            if let textView = descendants(hosting).compactMap({ $0 as? PRReviewDiffTextView }).first,
               textView.renderedIdentity != nil {
                return textView
            }
        }
        return nil
    }
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
