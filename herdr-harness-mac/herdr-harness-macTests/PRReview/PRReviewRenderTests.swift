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

    @Test("Viewed history shortcuts are exactly Control-Z and Control-Shift-Z")
    func viewedHistoryShortcuts() {
        #expect(PRReviewViewedHistoryShortcut.undoKey == KeyEquivalent("z"))
        #expect(PRReviewViewedHistoryShortcut.undoModifiers == .control)
        #expect(PRReviewViewedHistoryShortcut.redoKey == KeyEquivalent("z"))
        #expect(PRReviewViewedHistoryShortcut.redoModifiers == [.control, .shift])
    }

    @Test("Viewed history shortcut buttons use the non-fading Herdr style", arguments: ["Undo", "Redo"])
    func viewedHistoryShortcutStyles(action: String) throws {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "herdr-harness-mac/PRReview/Views/PRReviewFilesView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "Button(\"\(action) Viewed Change\")"))
        let modifiers = source[start.upperBound...]
        let end = try #require(modifiers.range(of: ".frame(width: 0, height: 0)"))
        #expect(modifiers[..<end.lowerBound].contains(".buttonStyle(.herdrPlain)"))
    }

    @Test("Undo restores the rendered row and checkbox viewed state", arguments: [false, true])
    func rendersRestoredViewedState(viewed: Bool) async throws {
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let store = demoStore()
        let file = try #require(store.comparisonFiles.first { $0.viewed == viewed })
        store.selectedPath = file.path
        let initialProgress = store.viewedProgress

        await store.setViewedRecordingUndo(paths: [file.path], viewed: !viewed)
        #expect(store.canUndoViewed)
        await store.undoViewed()
        #expect(store.viewedProgress == initialProgress)
        #expect(store.canRedoViewed)
        #expect(store.selectedPath == file.path)

        let size = CGSize(width: 1240, height: 820)
        let result = try await HerdrRenderHarness.render(
            "pr-review-undo-\(viewed ? "viewed" : "unviewed").png",
            size: size
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()

        let mounted = mount(PRReviewContainerView(store: store, canControl: true), size: size)
        defer { mounted.window.close() }
        await settle(mounted)
        let index = try #require(store.orderedFiles.firstIndex { $0.path == file.path })
        let elements = accessibilityDescendants(mounted.hosting)
        let row = try #require(elements.first { $0.accessibilityIdentifier() == "pr-review-file-\(index)" })
        let expectedValue = PRReviewViewedProgress.rowAccessibilityValue(viewed: viewed)
        #expect(expectedValue == (viewed ? "Viewed" : "Not viewed"))
        #expect(row.accessibilityValueDescription() == expectedValue)
        let toggle = try #require(elements.first { $0.accessibilityIdentifier() == "pr-review-viewed-\(index)" })
        #expect(toggle.accessibilityLabel() == "Viewed")
        #expect((toggle.accessibilityValue() as? NSNumber)?.boolValue == viewed)
        #expect(!elements.contains {
            $0.accessibilityLabel() == "Undo Viewed Change" || $0.accessibilityLabel() == "Redo Viewed Change"
        })
    }

    @Test("Viewed progress stays mounted in normal and compact filtered rails", arguments: [CGFloat(820), 420])
    func viewedProgressInFilesRail(height: CGFloat) async throws {
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let store = demoStore()
        let mounted = mount(PRReviewFilesView(store: store), size: CGSize(width: 1240, height: height))
        defer { mounted.window.close() }
        await settle(mounted)

        let initialProgress = store.viewedProgress
        let progress = try #require(accessibilityDescendants(mounted.hosting).first {
            $0.accessibilityIdentifier() == "pr-review-viewed-progress"
        })
        #expect(progress.accessibilityLabel() == initialProgress.accessibilityLabel)
        // macOS exposes the bar's numeric fraction as AXValue and the supplied
        // spoken summary as AXValueDescription.
        #expect(progress.accessibilityValueDescription() == initialProgress.accessibilityValue)
        #expect((progress.accessibilityValue() as? NSNumber)?.doubleValue == initialProgress.fraction)

        let unviewedFile = try #require(store.comparisonFiles.first { !$0.viewed })
        await store.setViewed(paths: [unviewedFile.path], viewed: true)
        await settle(mounted)
        let updatedProgress = store.viewedProgress
        #expect(updatedProgress.unviewed == initialProgress.unviewed - 1)
        #expect(accessibilityDescendants(mounted.hosting).contains {
            $0.accessibilityIdentifier() == "pr-review-viewed-progress"
                && $0.accessibilityValueDescription() == updatedProgress.accessibilityValue
        })

        store.impactFilter = .high
        store.hideViewed = true
        store.search = "no-synthetic-file-matches"
        await settle(mounted)
        #expect(store.orderedFiles.isEmpty)
        #expect(store.viewedProgress == updatedProgress)
        let filteredElements = accessibilityDescendants(mounted.hosting)
        #expect(filteredElements.contains {
            $0.accessibilityIdentifier() == "pr-review-viewed-progress"
                && $0.accessibilityValueDescription() == updatedProgress.accessibilityValue
        })
        #expect(filteredElements.contains { $0.accessibilityIdentifier() == "pr-review-no-filter-matches" })
        #expect(!filteredElements.contains { $0.accessibilityIdentifier() == "pr-review-all-viewed" })
    }

    @Test("Only viewed rows mount a textual badge and both rows announce their state")
    func viewedFileRows() async throws {
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        var unviewed = try #require(PRReviewDemo.snapshot().files.first)
        unviewed.viewed = false
        var viewed = unviewed
        viewed.viewed = true
        var unviewedToggleValue: Bool?
        var viewedToggleValue: Bool?
        var selectedRows: [Int] = []
        let unviewedRow = PRReviewFileRow(file: unviewed, index: 0, selected: false, guided: false,
                                        select: { selectedRows.append(0) }, setViewed: { unviewedToggleValue = $0 })
        let viewedRow = PRReviewFileRow(file: viewed, index: 1, selected: false, guided: false,
                                      select: { selectedRows.append(1) }, setViewed: { viewedToggleValue = $0 })

        // SwiftUI draws the badge without an NSView and hides it from AX to
        // avoid repeating the row value. Its intrinsic width still proves that
        // only the viewed row mounts the fixed-size checkmark/text capsule.
        let unviewedWidth = NSHostingView(rootView: unviewedRow.fixedSize()).fittingSize.width
        let viewedWidth = NSHostingView(rootView: viewedRow.fixedSize()).fittingSize.width
        #expect(viewedWidth > unviewedWidth + 30)

        let mounted = mount(VStack { unviewedRow; viewedRow }, size: CGSize(width: 820, height: 180))
        defer { mounted.window.close() }
        await settle(mounted)
        let elements = accessibilityDescendants(mounted.hosting)
        #expect(elements.contains {
            $0.accessibilityIdentifier() == "pr-review-file-0"
                && $0.accessibilityValueDescription() == "Not viewed"
        })
        #expect(elements.contains {
            $0.accessibilityIdentifier() == "pr-review-file-1"
                && $0.accessibilityValueDescription() == "Viewed"
        })
        for index in 0...1 {
            let toggle = try #require(elements.first { $0.accessibilityIdentifier() == "pr-review-viewed-\(index)" })
            #expect(toggle.accessibilityLabel() == "Viewed")
            #expect(toggle.accessibilityPerformPress())
        }
        #expect(unviewedToggleValue == true)
        #expect(viewedToggleValue == false)
        #expect(selectedRows.isEmpty, "Toggling viewed must not invoke the row selection action")
    }

    @Test("All-viewed state offers an action that restores the file list")
    func allViewedFilesState() async throws {
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let store = demoStore()
        await store.setViewed(paths: store.comparisonFiles.map(\.path), viewed: true)
        let allPaths = store.orderedFiles.map(\.path)
        #expect(!allPaths.isEmpty)
        store.hideViewed = true
        #expect(store.orderedFiles.isEmpty)
        #expect(store.viewedProgress.isComplete)

        let mounted = mount(PRReviewFilesView(store: store), size: CGSize(width: 1240, height: 820))
        defer { mounted.window.close() }
        await settle(mounted)
        let elements = accessibilityDescendants(mounted.hosting)
        #expect(elements.contains { $0.accessibilityIdentifier() == "pr-review-all-viewed" })
        #expect(!elements.contains { $0.accessibilityIdentifier() == "pr-review-no-filter-matches" })
        #expect(elements.contains {
            $0.accessibilityIdentifier() == "pr-review-viewed-progress"
                && $0.accessibilityValueDescription() == store.viewedProgress.accessibilityValue
        })
        let showViewed = try #require(elements.first {
            $0.accessibilityRole() == .button && $0.accessibilityLabel() == PRReviewViewedProgress.showViewedLabel
        })
        #expect(showViewed.accessibilityPerformPress())
        await settle(mounted)
        #expect(!store.hideViewed)
        #expect(store.orderedFiles.map(\.path) == allPaths)
        #expect(!accessibilityDescendants(mounted.hosting).contains {
            $0.accessibilityIdentifier() == "pr-review-all-viewed"
        })

        store.search = "no-synthetic-file-matches"
        await settle(mounted)
        let filteredElements = accessibilityDescendants(mounted.hosting)
        #expect(filteredElements.contains { $0.accessibilityIdentifier() == "pr-review-no-filter-matches" })
        #expect(!filteredElements.contains { $0.accessibilityIdentifier() == "pr-review-all-viewed" })
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

    @Test("Header actions stay inline until crowded, then stack")
    func headerActionsReflowWhenCrowded() {
        struct Fixture: View {
            var body: some View {
                PRReviewHeaderActionsLayout(spacing: 8) {
                    Color.red.frame(width: 100, height: 20)
                    Color.blue.frame(width: 300, height: 20)
                }
            }
        }

        // 100 + 8 + 300 = 408 fits in 420, so both groups share one row.
        #expect(hostingHeight(Fixture().frame(width: 420)) == 20)
        // The same groups need more than 350 and stack into two left rows.
        #expect(hostingHeight(Fixture().frame(width: 350)) == 48)
        #expect(PRReviewHeaderActionsLayout.Arrangement.resolve(
            groupWidths: [100, 300], availableWidth: 420, spacing: 8
        ) == .inline)
        #expect(PRReviewHeaderActionsLayout.Arrangement.resolve(
            groupWidths: [100, 300], availableWidth: 350, spacing: 8
        ) == .stacked)
    }

    @Test(
        "Deleted long paths stay usable at the minimum pop-out size and largest text",
        arguments: [false, true]
    )
    func deletedLongPathAtMinimumSizeAndLargestText(expanded: Bool) async throws {
        let size = CGSize(width: 720, height: 520)
        let longPath = "Sources/Legacy/Compatibility/SeedCatalogLegacyCompatibilityShimsAndMigrationHelpers.swift"
        let removedLine = "enum SeedCatalogLegacyCompatibilityShims { static let enabled = false }"

        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        let snapshot = PRReviewDemo.snapshot()
        let file = try #require(snapshot.files.first { $0.path == longPath })
        #expect(file.isDeleted)
        #expect(file.deletions == 2)
        store.receive(snapshot)
        store.selectedPath = longPath
        store.diff = PRReviewDemo.diff()
        if expanded {
            store.setDeletedContentExpanded(true, path: longPath)
        }

        let hosting: NSView = NSHostingView(rootView:
            PRReviewFilesView(store: store)
                .frame(width: size.width, height: size.height)
                .environment(\.herdrFontScale, .xxxLarge)
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

        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }

        // Readable labels: the header copy comes from the shared deleted-file
        // presentation; the complete long path is the value its text, hover,
        // and accessibility label receive. The UI suite asserts that AX label
        // end to end with `headerPath`.
        #expect(store.selectedPath == longPath)
        #expect(file.path == longPath,
                "The header receives the complete long path for text, hover, and accessibility")
        #expect(PRReviewDeletedFileDisclosure.badgeLabel == "Deleted")
        #expect(PRReviewDeletedFileDisclosure.summary(deletions: file.deletions) == "Deleted · 2 lines removed")
        #expect(PRReviewDeletedFileDisclosure.actionLabel(expanded: expanded)
            == (expanded ? "Hide deleted content" : "Show deleted content"))
        #expect(PRReviewDeletedFileDisclosure.stateDescription(expanded: expanded)
            == (expanded ? "Expanded" : "Collapsed"))
        #expect(PRReviewDeletedFileDisclosure.hiddenDetail(deletions: file.deletions)
            == "2 removed lines are hidden. Choose Show deleted content to inspect them.")

        if expanded {
            let textView = try #require(await waitForDiffTextView(in: hosting, window: window))
            #expect(textView.renderedPlainText.contains(removedLine),
                    "Expanded deleted content renders the long-path removal hunk")
        } else {
            #expect(
                descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
                "A collapsed deleted file mounts no removed code at the minimum size"
            )
        }

        // Controls contained: every header action, including the disclosure,
        // stays inside the diff pane; the layout test above covers reflow.
        let split = try #require(descendants(hosting).compactMap { $0 as? NSSplitView }.first)
        // A split view's raw `subviews` end with its trailing divider, so the
        // last arranged pane is the diff pane that owns the header controls.
        let detail = try #require(split.arrangedSubviews.last)
        let detailRect = detail.convert(detail.bounds, to: hosting)
        let actionButtons = descendants(detail).filter {
            String(describing: type(of: $0)).contains("FocusRingView")
        }
        #expect(actionButtons.count >= 5,
                "The header should mount its disclosure and navigation buttons")
        for button in actionButtons {
            let frame = button.convert(button.bounds, to: hosting)
            #expect(
                detailRect.insetBy(dx: -1, dy: -1).contains(frame),
                "Header action \(type(of: button)) must stay inside the diff pane"
            )
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
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
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

        #expect(accessibilityDescendants(hosting).contains {
            $0.accessibilityIdentifier() == "pr-review-viewed-progress"
        }, "Popped-out windows share the Files rail's viewed progress")

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
        // Mono × Herdr: 20px rows at the 12px code size, set by the Mac theme.
        #expect(values["lineHeight"] as? String == HerdrWebTheme.diffLineHeight)
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

    private typealias MountedView = (hosting: NSView, window: NSWindow)

    private func mount(_ view: some View, size: CGSize) -> MountedView {
        let hosting = NSHostingView(rootView:
            view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        return (hosting, window)
    }

    private func settle(_ mounted: MountedView) async {
        for _ in 0..<8 {
            mounted.hosting.layoutSubtreeIfNeeded()
            mounted.window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// SwiftUI builds its AX tree on demand. Opt this test host in without
    /// requiring VoiceOver or system-wide Accessibility permissions, and restore
    /// the previous setting after each test. AppKit exposes this application
    /// attribute only through its informal accessibility API.
    private func enableAccessibility() -> () -> Void {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = application.accessibilityAttributeValue(attribute) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        return { application.accessibilitySetValue(previous, forAttribute: attribute) }
    }

    /// SwiftUI's AccessibilityNode implements AX selectors without adopting the
    /// full NSAccessibilityProtocol. Use optional Objective-C dispatch for these
    /// nodes as well as native views; no private SwiftUI API is needed.
    private struct AccessibilityElement {
        let object: AnyObject
        func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() }
        func accessibilityLabel() -> String? { object.accessibilityLabel?() }
        func accessibilityValue() -> Any? {
            // AnyObject's overloaded accessibilityValue selector can select a
            // String-returning signature and misbridge numeric checkbox/bar
            // values. KVC preserves the public AX getter's actual value type.
            guard let object = object as? NSObject,
                  object.responds(to: #selector(NSView.accessibilityValue)) else { return nil }
            return object.value(forKey: "accessibilityValue")
        }
        func accessibilityValueDescription() -> String? { object.accessibilityValueDescription?() }
        func accessibilityRole() -> NSAccessibility.Role? { object.accessibilityRole?() }
        func accessibilityPerformPress() -> Bool { object.accessibilityPerformPress?() ?? false }
    }

    /// Traverse the view and accessibility hierarchies, deduplicating nodes.
    private func accessibilityDescendants(_ view: NSView) -> [AccessibilityElement] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: AnyObject) -> [AccessibilityElement] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [AccessibilityElement(object: object)] + (object.accessibilityChildren?() ?? []).flatMap {
                collect($0 as AnyObject)
            }
        }
        return descendants(view).flatMap { collect($0) }
    }

    /// The height SwiftUI needs for `view` at its given width, measured off
    /// screen so the header's wrap decision is directly testable.
    @MainActor
    private func hostingHeight(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
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
