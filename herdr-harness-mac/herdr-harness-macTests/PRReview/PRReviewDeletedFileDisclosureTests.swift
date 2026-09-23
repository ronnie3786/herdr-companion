import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review deleted-file disclosure", .serialized)
struct PRReviewDeletedFileDisclosureTests {
    @Test("Only an explicit deleted status is classified as deleted")
    func statusClassificationUsesExplicitDeletedStatus() {
        var file = PRReviewDemo.snapshot().files[0]
        #expect(!file.isDeleted)
        #expect(file.deletions > 0, "A modified file with removal lines must not be treated as deleted")
        file.status = "deleted"
        #expect(file.isDeleted)
        file.status = "renamed"
        #expect(!file.isDeleted)

        var diffFile = PRReviewDemo.diff().files[0]
        diffFile.deletions = 12
        #expect(!diffFile.isDeleted)
        diffFile.status = "deleted"
        #expect(diffFile.isDeleted)
        #expect(!PRReviewDeletedStatus.matches("delete"))
        #expect(PRReviewDeletedStatus.matches("deleted"))
    }

    @Test("Deleted disclosure defaults collapsed, toggles, and leaves viewed state alone")
    func disclosureDefaultsAndToggles() {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        let viewedBefore = store.snapshot?.files.first { $0.path == path }?.viewed

        #expect(!store.isDeletedContentExpanded(path: path))
        #expect(store.expandedDeletedPaths.isEmpty)
        store.setDeletedContentExpanded(true, path: path)
        #expect(store.isDeletedContentExpanded(path: path))
        #expect(store.expandedDeletedPaths == [path])
        store.setDeletedContentExpanded(false, path: path)
        #expect(!store.isDeletedContentExpanded(path: path))
        #expect(store.snapshot?.files.first { $0.path == path }?.viewed == viewedBefore)
    }

    @Test("Disclosure survives file navigation, viewed updates, and unchanged polling")
    func disclosureSurvivesNavigationAndPolling() async {
        let store = makeStore()
        let deleted = PRReviewDemo.snapshot().files[0].path
        let other = PRReviewDemo.snapshot().files[1].path

        store.setDeletedContentExpanded(true, path: deleted)
        store.selectedPath = other
        store.selectedPath = deleted
        #expect(store.isDeletedContentExpanded(path: deleted))

        await store.setViewed(paths: [other], viewed: true)
        #expect(store.isDeletedContentExpanded(path: deleted),
                "A viewed update must not reset the disclosure")

        var polled = PRReviewDemo.snapshot()
        polled.files[0].status = "deleted"
        polled.review.revision += 1
        polled.review.title = "Metadata-only change"
        store.receive(polled)
        #expect(store.isDeletedContentExpanded(path: deleted),
                "A metadata revision bump must not reset the disclosure")
    }

    @Test("Disclosure resets when the host, review, or revision scope changes")
    func disclosureResetsAcrossScopes() {
        let path = PRReviewDemo.snapshot().files[0].path

        let hostStore = makeStore()
        hostStore.setDeletedContentExpanded(true, path: path)
        hostStore.configure(client: nil, machineID: "other-host", demo: false)
        hostStore.select(PRReviewDemo.reviewID)
        var snapshot = PRReviewDemo.snapshot()
        snapshot.files[0].status = "deleted"
        hostStore.receive(snapshot)
        #expect(!hostStore.isDeletedContentExpanded(path: path))

        let reviewStore = makeStore()
        reviewStore.setDeletedContentExpanded(true, path: path)
        reviewStore.select(PRReviewDemo.secondReviewID)
        #expect(!reviewStore.isDeletedContentExpanded(path: path))

        let baseStore = makeStore()
        baseStore.setDeletedContentExpanded(true, path: path)
        var rebased = PRReviewDemo.snapshot()
        rebased.files[0].status = "deleted"
        rebased.review.baseSHA = "new-base"
        rebased.review.revision += 1
        baseStore.receive(rebased)
        #expect(!baseStore.isDeletedContentExpanded(path: path))

        let headStore = makeStore()
        headStore.setDeletedContentExpanded(true, path: path)
        var pushed = PRReviewDemo.snapshot()
        pushed.files[0].status = "deleted"
        pushed.review.headSHA = "new-head"
        pushed.review.revision += 1
        headStore.receive(pushed)
        #expect(!headStore.isDeletedContentExpanded(path: path))
    }

    @Test("The same path in a different scope keeps its own independent disclosure")
    func identicalPathsInDifferentScopesStayIndependent() {
        let path = "Sources/Catalog/SeedCatalog.swift"
        let first = makeStore(machineID: "machine-a")
        first.setDeletedContentExpanded(true, path: path)

        let second = makeStore(machineID: "machine-b")
        #expect(!second.isDeletedContentExpanded(path: path))
        second.setDeletedContentExpanded(true, path: path)
        #expect(first.isDeletedContentExpanded(path: path))
        #expect(second.isDeletedContentExpanded(path: path))

        let otherReview = makeStore(machineID: "machine-a", reviewID: PRReviewDemo.secondReviewID)
        #expect(!otherReview.isDeletedContentExpanded(path: path))
    }

    @Test("An explicit line navigation reveals deleted content and a stale request cannot reopen it")
    func lineNavigationRevealsDeletedContent() {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        #expect(!store.isDeletedContentExpanded(path: path))

        store.scroll(to: path, line: 8, side: .before)
        #expect(store.scrollRequest?.path == path)
        #expect(store.scrollRequest?.token == 1)
        #expect(store.isDeletedContentExpanded(path: path))

        store.setDeletedContentExpanded(false, path: path)
        #expect(!store.isDeletedContentExpanded(path: path))

        var polled = PRReviewDemo.snapshot()
        polled.files[0].status = "deleted"
        polled.review.revision += 1
        store.receive(polled)
        #expect(!store.isDeletedContentExpanded(path: path),
                "A stale navigation request must not reopen manually hidden content")
    }

    @Test("Deleted lookup only uses explicit statuses from the snapshot or the loaded diff")
    func deletedLookupUsesExplicitStatus() {
        let modified = makeStore(deletedIndexes: [])
        let path = PRReviewDemo.snapshot().files[0].path
        #expect(!modified.isDeletedFile(path: path))
        #expect(!modified.isDeletedFile(path: "Sources/Unknown.swift"))

        var diff = PRReviewDemo.diff()
        diff.files[0].status = "deleted"
        modified.diff = diff
        #expect(modified.isDeletedFile(path: path))
    }

    @Test("A deleted-to-modified revision stops using the retained diff while the replacement loads")
    func staleDeletedDiffIsNotUsedAcrossRevisions() async throws {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        var staleDiff = PRReviewDemo.diff()
        staleDiff.files[0].status = "deleted"
        store.selectedPath = path
        store.diff = staleDiff
        #expect(store.isDeletedFile(path: path), "A matching revision's diff can report deletion")

        // Polling replaces the snapshot before its diff arrives: the same path
        // is now modified at a new head. The retained diff belongs to the
        // previous revision and must not keep labeling the file deleted.
        var updated = PRReviewDemo.snapshot()
        updated.files[0].status = "modified"
        updated.review.headSHA = "new-head"
        updated.review.revision += 1
        store.receive(updated)

        #expect(store.diff != nil, "The previous diff is retained while the replacement is pending")
        #expect(!store.isDeletedFile(path: path),
                "A stale diff from the previous head must not keep the Deleted state")

        // A replacement that fails leaves the same retained diff in place, so
        // the lookup must stay truthful after the error, too.
        let client = TestPRReviewClient(diffHandler: { _, _ in throw APIError.invalidResponse })
        store.reconnect(client: client, machineID: "synthetic-host", demo: false)
        store.selectedPath = path
        await store.loadDiff(for: path)
        #expect(store.currentDiffLoadError != nil)
        #expect(!store.isDeletedFile(path: path))
    }

    @Test("Hiding deleted content clears line visibility reported for it")
    func hidingDeletedContentClearsVisibleLineReporting() {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.setDeletedContentExpanded(true, path: path)
        store.visibleLines = (path, 8, 8, .before)

        store.setDeletedContentExpanded(false, path: path)

        #expect(store.visibleLines == nil)
    }

    @Test("Deleted presentation copy names the state and protects an ask draft")
    func deletedPresentationCopy() {
        #expect(PRReviewDeletedFileDisclosure.badgeLabel == "Deleted")
        #expect(PRReviewDeletedFileDisclosure.actionLabel(expanded: false) == "Show deleted content")
        #expect(PRReviewDeletedFileDisclosure.actionLabel(expanded: true) == "Hide deleted content")
        #expect(PRReviewDeletedFileDisclosure.stateDescription(expanded: false) == "Collapsed")
        #expect(PRReviewDeletedFileDisclosure.stateDescription(expanded: true) == "Expanded")
        #expect(PRReviewDeletedFileDisclosure.summary(deletions: 1) == "Deleted · 1 line removed")
        #expect(PRReviewDeletedFileDisclosure.summary(deletions: 3) == "Deleted · 3 lines removed")
        #expect(PRReviewDeletedFileDisclosure.accessibilityIdentifier == "pr-review-deleted-content-disclosure")

        #expect(PRReviewDeletedFileDisclosure.canToggle(expanded: true, hasQuestionDraft: false))
        #expect(PRReviewDeletedFileDisclosure.canToggle(expanded: false, hasQuestionDraft: true))
        #expect(PRReviewDeletedFileDisclosure.canToggle(expanded: false, hasQuestionDraft: false))
        #expect(!PRReviewDeletedFileDisclosure.canToggle(expanded: true, hasQuestionDraft: true))
    }

    @Test("A modified file with removal lines mounts its renderer without disclosure")
    func modifiedFilesStayExpandedWithoutDisclosure() async throws {
        let store = makeStore(deletedIndexes: [])
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.diff = PRReviewDemo.diff()
        #expect(store.snapshot?.files[0].isDeleted == false)

        let mounted = mountDiffView(store: store)
        defer { mounted.window.close() }

        let textView = try #require(await waitForDiffTextView(in: mounted))
        #expect(textView.renderedPlainText.contains("struct SeedCatalog {}"))
        #expect(store.isDeletedContentExpanded(path: path) == false)
    }

    @Test("A deleted file starts without a code renderer and toggles it on demand")
    func deletedFileStartsWithNoMountedRenderer() async throws {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.diff = deletedDiff()

        let mounted = mountDiffView(store: store)
        defer { mounted.window.close() }
        await settle(mounted)

        #expect(descendants(mounted.hosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
                "A selected deleted file must not mount removed code before disclosure")
        #expect(!store.isDeletedContentExpanded(path: path))

        store.setDeletedContentExpanded(true, path: path)
        let textView = try #require(await waitForDiffTextView(in: mounted))
        #expect(textView.renderedPlainText.contains("-old"))

        store.setDeletedContentExpanded(false, path: path)
        let removed = await waitForRendererRemoval(in: mounted)
        #expect(removed, "Collapsing a deleted file must unmount the code renderer")
    }

    @Test("A new highlight request reveals deleted content in the mounted view")
    func highlightRequestRevealsDeletedContentInMountedView() async throws {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.diff = deletedDiff()

        let mounted = mountDiffView(store: store)
        defer { mounted.window.close() }
        await settle(mounted)
        #expect(!store.isDeletedContentExpanded(path: path))

        store.highlightLines(path: path, start: 8, end: 8, side: .before)
        for _ in 0..<80 {
            if store.isDeletedContentExpanded(path: path) { break }
            await settleOnce(mounted)
        }
        #expect(store.isDeletedContentExpanded(path: path),
                "Highlighting a line in a collapsed deleted file must reveal the content")

        let textView = try #require(await waitForDiffTextView(in: mounted))
        #expect(textView.renderedPlainText.contains("-old"))
    }

    @Test("Every explicit highlight request reveals deleted content, even when repeated")
    func repeatedHighlightRequestsRevealDeletedContent() {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path

        store.highlightLines(path: path, start: 8, end: 8, side: .before)
        #expect(store.highlight?.path == path)
        #expect(store.highlight?.start == 8)
        #expect(store.highlight?.end == 8)
        #expect(store.highlight?.side == .before)
        #expect(store.isDeletedContentExpanded(path: path))

        store.setDeletedContentExpanded(false, path: path)
        #expect(!store.isDeletedContentExpanded(path: path))

        store.highlightLines(path: path, start: 8, end: 8, side: .before)
        #expect(store.isDeletedContentExpanded(path: path),
                "Identical coordinates are still a new request and must reveal the content")
    }

    @Test("A highlight request received before its view mounts is not lost")
    func highlightBeforeMountingRevealsContent() async throws {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.diff = deletedDiff()

        // The request lands while no Files view exists yet.
        store.highlightLines(path: path, start: 8, end: 8, side: .before)
        #expect(store.isDeletedContentExpanded(path: path))

        let mounted = mountDiffView(store: store)
        defer { mounted.window.close() }
        let textView = try #require(await waitForDiffTextView(in: mounted))
        #expect(textView.renderedPlainText.contains("-old"),
                "A pre-mount request must still render the revealed removal hunk")
    }

    @Test("Ordinary rerenders never reopen manually collapsed deleted content")
    func rerendersDoNotReopenCollapsedContent() async throws {
        let store = makeStore()
        let path = PRReviewDemo.snapshot().files[0].path
        store.selectedPath = path
        store.diff = deletedDiff()

        let mounted = mountDiffView(store: store)
        defer { mounted.window.close() }
        await settle(mounted)
        store.setDeletedContentExpanded(true, path: path)
        _ = try #require(await waitForDiffTextView(in: mounted))
        store.setDeletedContentExpanded(false, path: path)
        #expect(await waitForRendererRemoval(in: mounted))

        // A refresh inside the same revision scope republishes the deleted
        // snapshot; that is an ordinary rerender, not a highlight request.
        var polled = PRReviewDemo.snapshot()
        polled.files[0].status = "deleted"
        store.receive(polled)
        await settle(mounted)
        #expect(!store.isDeletedContentExpanded(path: path))
        #expect(
            descendants(mounted.hosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
            "A rerender must not mount removed code after a manual collapse"
        )
    }

    @Test("Binary and empty deleted diffs never mount the text renderer")
    func binaryAndEmptyDeletedDiffsNeverMountRenderer() async throws {
        for variant in ["binary", "empty"] {
            let store = makeStore()
            let path = PRReviewDemo.snapshot().files[0].path
            store.selectedPath = path
            var diff = deletedDiff()
            diff.files[0].hunks = []
            if variant == "binary" { diff.files[0].binary = true }
            store.diff = diff

            let mounted = mountDiffView(store: store)
            defer { mounted.window.close() }
            await settle(mounted)

            #expect(
                descendants(mounted.hosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty,
                "\(variant) deleted diffs must keep their honest message instead of mounting code"
            )
        }
    }

    // MARK: - Helpers

    private func makeStore(
        machineID: String = "synthetic-host",
        reviewID: String = PRReviewDemo.reviewID,
        deletedIndexes: Set<Int> = [0]
    ) -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: machineID, demo: false)
        store.select(reviewID)
        var snapshot = PRReviewDemo.snapshot(for: reviewID)
        for index in deletedIndexes where snapshot.files.indices.contains(index) {
            snapshot.files[index].status = "deleted"
        }
        store.receive(snapshot)
        return store
    }

    private func deletedDiff() -> PRReviewDiff {
        var diff = PRReviewDemo.diff()
        diff.files[0].status = "deleted"
        diff.files[0].hunks = [diff.files[0].hunks[1]]
        return diff
    }

    private func mountDiffView(
        store: PRReviewStore,
        size: CGSize = CGSize(width: 980, height: 620)
    ) -> (window: NSWindow, hosting: NSView) {
        let hosting: NSView = NSHostingView(rootView:
            PRReviewDiffView(store: store)
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
        return (window, hosting)
    }

    private func settle(_ mounted: (window: NSWindow, hosting: NSView)) async {
        for _ in 0..<8 {
            await settleOnce(mounted)
        }
    }

    private func settleOnce(_ mounted: (window: NSWindow, hosting: NSView)) async {
        mounted.hosting.layoutSubtreeIfNeeded()
        mounted.window.displayIfNeeded()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(25))
    }

    private func waitForDiffTextView(
        in mounted: (window: NSWindow, hosting: NSView)
    ) async -> PRReviewDiffTextView? {
        for _ in 0..<400 {
            await settleOnce(mounted)
            if let textView = descendants(mounted.hosting).compactMap({ $0 as? PRReviewDiffTextView }).first,
               textView.renderedIdentity != nil {
                return textView
            }
        }
        return nil
    }

    private func waitForRendererRemoval(
        in mounted: (window: NSWindow, hosting: NSView)
    ) async -> Bool {
        for _ in 0..<100 {
            await settleOnce(mounted)
            if descendants(mounted.hosting).compactMap({ $0 as? PRReviewDiffTextView }).isEmpty {
                return true
            }
        }
        return descendants(mounted.hosting).compactMap { $0 as? PRReviewDiffTextView }.isEmpty
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
