import Foundation
import Testing
@testable import herdr_harness_mac

/// End-to-end coverage for the local PR Review comment workflow: composition
/// is frozen to its origin, saves are shared across windows, navigation never
/// guesses a stale location, and the manual GitHub handoff only copies or
/// opens links.
@MainActor
@Suite("PR Review comment integration", .serialized)
struct PRReviewCommentIntegrationTests {
    // MARK: - Captured origin and persistence

    @Test("A captured selection saves its exact text and frozen revision")
    func capturedSelectionSavesExactTextAndRevision() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        let composition = try #require(session.composition)
        #expect(composition.machineID == "machine-a")
        #expect(composition.reviewID == PRReviewDemo.reviewID)
        #expect(composition.anchor.baseSHA == "base")
        #expect(composition.anchor.headSHA == "head")
        #expect(composition.anchor.path == "Sources/Catalog/SeedCatalog.swift")
        #expect(composition.anchor.spans == [PRReviewCommentSpan(side: .after, start: 1, end: 2)])
        #expect(composition.anchor.code == "import Foundation\nstruct SeedCatalog {}")
        #expect(composition.prURL == "https://github.com/example-owner/garden-planner/pull/42")

        let body = "  Keep the 🧪 seed\n\tand exact trailing spaces  \n\n`inline()` stays."
        session.draftBody = body
        #expect(session.canSave)
        session.save()

        #expect(session.saveError == nil)
        #expect(session.composition == nil)
        let saved = try #require(
            commentStore.comments(machineID: "machine-a", reviewID: PRReviewDemo.reviewID).first
        )
        #expect(saved.body == body)
        #expect(saved.anchor == composition.anchor)
        #expect(saved.prURL == "https://github.com/example-owner/garden-planner/pull/42")
        #expect(session.visibleComments.map(\.id) == [saved.id])
    }

    @Test("A refresh while editing neither retargets the draft nor rewrites its anchor")
    func refreshWhileEditingKeepsFrozenOrigin() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Review this before merge"

        var refreshed = PRReviewDemo.snapshot()
        refreshed.review.revision = 2
        refreshed.review.headSHA = "head-2"
        store.receive(refreshed)
        #expect(store.snapshot?.review.headSHA == "head-2")

        // The draft stays attached to the revision it was composed against.
        #expect(session.composition?.anchor.headSHA == "head")
        session.save()

        #expect(session.saveError == nil)
        let saved = try #require(commentStore.comments(machineID: "machine-a", reviewID: PRReviewDemo.reviewID).first)
        #expect(saved.anchor.headSHA == "head")
        #expect(saved.body == "Review this before merge")
    }

    @Test("Switching review scope never retargets an open draft")
    func scopeSwitchKeepsCapturedOrigin() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Saved to the origin review"

        // Another window navigates this session's list elsewhere. The editor
        // is modal in the app; this proves the draft keeps its own origin.
        session.updateScope(machineID: "machine-b", reviewID: "prr_other")
        session.save()

        #expect(session.saveError == nil)
        #expect(commentStore.comments(machineID: "machine-a", reviewID: PRReviewDemo.reviewID).count == 1)
        #expect(commentStore.comments(machineID: "machine-b", reviewID: "prr_other").isEmpty)
    }

    @Test("Mixed before and after selections keep their own sides")
    func mixedSideSelectionRoundTrips() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        let selection = PRReviewSelection(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [
                .init(side: .after, start: 1, end: 2),
                .init(side: .before, start: 8, end: 8),
            ],
            text: "import Foundation\nstruct SeedCatalog {}\nold"
        )
        #expect(session.beginComposition(selection: selection, store: store))
        session.draftBody = "Added and removed context"
        session.save()

        #expect(session.saveError == nil)
        let saved = try #require(commentStore.comments.first)
        #expect(saved.anchor.spans.map(\.side) == [.after, .before])
        #expect(saved.anchor.spans.last?.start == 8)
        #expect(saved.anchor.code == selection.text)
    }

    @Test("Demo mode persists through a temporary-store relaunch argument")
    func demoRelaunchTemporaryStore() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "herdr-comment-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "pr-review-comments-v1.json").path
        let suite = "PRReviewCommentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let arguments = [
            "HerdrTests",
            "-HerdrDemoMode",
            "-HerdrPRReviewCommentStorePath",
            path,
        ]

        let first = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: arguments,
            userDefaults: defaults,
            configuredMachines: []
        )
        let draft = PRReviewCommentDraft(
            machineID: "demo",
            reviewID: PRReviewDemo.reviewID,
            prURL: "https://github.com/example-owner/garden-planner/pull/42",
            anchor: commentAnchor(),
            body: "Survives relaunch"
        )
        _ = try first.prReviewComments.insert(draft, diff: PRReviewDemo.diff())

        let second = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: arguments,
            userDefaults: defaults,
            configuredMachines: []
        )
        #expect(second.prReviewComments.loadError == nil)
        #expect(
            second.prReviewComments.comments(machineID: "demo", reviewID: PRReviewDemo.reviewID).map(\.body)
                == ["Survives relaunch"]
        )
    }

    // MARK: - Failure recovery

    @Test("A failed write keeps the draft available for retry and reports no success")
    func failedWriteKeepsDraftForRetry() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "herdr-comment-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appending(path: "not-a-directory")
        try Data("synthetic block".utf8).write(to: blocker)
        let commentStore = PRReviewCommentStore(url: blocker.appending(path: "comments.json"))
        let store = demoStore(machineID: "machine-a")
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        let body = "  Keep this draft\nwith its exact spacing  "
        session.draftBody = body
        session.save()

        #expect(session.composition != nil)
        #expect(session.draftBody == body)
        #expect(session.saveError == PRReviewCommentStoreError.writeFailed.errorDescription)
        #expect(commentStore.comments.isEmpty)

        try FileManager.default.removeItem(at: blocker)
        session.save()
        #expect(session.saveError == nil)
        #expect(session.composition == nil)
        #expect(commentStore.comments.first?.body == body)
    }

    @Test("Corrupt storage is preserved and blocks a save without losing the draft")
    func corruptStorageBlocksSaveAndPreservesFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "herdr-comment-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "comments.json")
        let original = Data("{\"version\":1,\"comments\":[".utf8)
        try original.write(to: url)
        let commentStore = PRReviewCommentStore(url: url)
        #expect(commentStore.loadError == .corruptStorage)
        let store = demoStore(machineID: "machine-a")
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "This must not be lost"
        session.save()

        #expect(session.composition != nil)
        #expect(session.draftBody == "This must not be lost")
        #expect(session.saveError == PRReviewCommentStoreError.storageUnavailable.errorDescription)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("A dirty cancel asks before discarding; a clean cancel does not")
    func dirtyCancelConfirmation() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Unfinished thought"
        session.cancelComposition()

        #expect(session.isConfirmingDiscard)
        #expect(session.composition != nil)
        #expect(session.draftBody == "Unfinished thought")
        #expect(commentStore.comments.isEmpty)

        session.keepEditing()
        #expect(!session.isConfirmingDiscard)
        #expect(session.composition != nil)

        session.cancelComposition()
        session.confirmDiscard()
        #expect(session.composition == nil)
        #expect(session.draftBody.isEmpty)
        #expect(commentStore.comments.isEmpty)

        // A blank draft cancels immediately.
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.cancelComposition()
        #expect(!session.isConfirmingDiscard)
        #expect(session.composition == nil)
        #expect(session.visibleComments.isEmpty)
    }

    @Test("A stale edit from another window cannot overwrite newer text")
    func staleEditIsRejectedAndDraftKept() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let first = PRReviewCommentsSession(store: commentStore)
        let second = PRReviewCommentsSession(store: commentStore)
        first.updateScope(from: store)
        second.updateScope(from: store)

        #expect(first.beginComposition(selection: catalogSelection(), store: store))
        first.draftBody = "First version"
        first.save()
        let comment = try #require(commentStore.comments.first)

        first.beginEditing(comment)
        second.beginEditing(comment)
        second.draftBody = "Newer version from the other window"
        second.save()
        #expect(second.saveError == nil)

        first.draftBody = "Stale overwrite"
        first.save()
        #expect(first.composition != nil)
        #expect(first.draftBody == "Stale overwrite")
        #expect(first.saveError?.contains("changed in another window") == true)
        #expect(commentStore.comment(id: comment.id)?.body == "Newer version from the other window")
    }

    // MARK: - Shared windows and scoping

    @Test("Main and popped-out windows observe the same saved records")
    func sharedStoreAcrossWindows() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let main = PRReviewCommentsSession(store: commentStore)
        main.updateScope(from: store)
        let windowSession = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID),
            comments: PRReviewCommentsSession(store: commentStore)
        )
        windowSession.comments.updateScope(from: store)

        #expect(windowSession.comments.beginComposition(selection: catalogSelection(), store: store))
        windowSession.comments.draftBody = "From the pop-out"
        windowSession.comments.save()

        #expect(windowSession.comments.saveError == nil)
        #expect(main.visibleComments.map(\.body) == ["From the pop-out"])
        #expect(main.count(machineID: "machine-a", reviewID: PRReviewDemo.reviewID) == 1)

        let saved = try #require(main.visibleComments.first)
        main.beginEditing(saved)
        main.draftBody = "Edited in the main window"
        main.save()
        #expect(windowSession.comments.visibleComments.first?.body == "Edited in the main window")
    }

    @Test("Duplicate labels and PR numbers on distinct hosts and reviews stay isolated")
    func hostAndReviewIsolation() throws {
        let commentStore = PRReviewCommentStore(inMemory: true)
        let firstStore = demoStore(machineID: "machine-a")
        let secondStore = demoStore(machineID: "machine-b", reviewID: PRReviewDemo.secondReviewID)
        let first = PRReviewCommentsSession(store: commentStore)
        let second = PRReviewCommentsSession(store: commentStore)
        first.updateScope(from: firstStore)
        second.updateScope(from: secondStore)

        #expect(first.beginComposition(selection: catalogSelection(), store: firstStore))
        first.draftBody = "Host A review"
        first.save()

        #expect(second.beginComposition(selection: reminderSelection(), store: secondStore))
        second.draftBody = "Host B review"
        second.save()

        #expect(first.visibleComments.map(\.body) == ["Host A review"])
        #expect(second.visibleComments.map(\.body) == ["Host B review"])
        #expect(first.count(machineID: "machine-b", reviewID: PRReviewDemo.secondReviewID) == 1)
        #expect(commentStore.comments.count == 2)
    }

    @Test("Archiving a review keeps its saved comments readable")
    func archivedReviewRetainsComments() throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)

        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Keep after archiving"
        session.save()

        var archived = PRReviewDemo.snapshot()
        archived.review.archivedAt = "2026-01-14T14:30:00Z"
        archived.review.status = .ready
        store.receive(archived)

        #expect(session.visibleComments.map(\.body) == ["Keep after archiving"])
        let comment = try #require(session.visibleComments.first)
        #expect(session.locationStatus(
            for: comment,
            review: store.snapshot?.review,
            currentFilePaths: nil
        ) == .current)
    }

    // MARK: - Reveal in diff

    @Test("Show in diff clears filters, selects Files, and highlights the saved span")
    func showInDiffRevealsFilteredFile() async throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Navigate to this"
        session.save()
        let comment = try #require(commentStore.comments.first)

        store.tab = .context
        store.impactFilter = .low
        store.hideViewed = true
        store.search = "no-synthetic-match"
        store.selectedPath = "Sources/Catalog/SyncClient.swift"

        await session.showInDiff(comment, store: store)

        #expect(session.navigationMessage == nil)
        #expect(store.tab == .files)
        #expect(store.impactFilter == .all)
        #expect(store.hideViewed == false)
        #expect(store.search.isEmpty)
        #expect(store.selectedPath == "Sources/Catalog/SeedCatalog.swift")
        #expect(store.highlight?.path == "Sources/Catalog/SeedCatalog.swift")
        #expect(store.highlight?.start == 1)
        #expect(store.highlight?.end == 2)
        #expect(store.highlight?.side == .after)
        #expect(store.scrollRequest?.path == "Sources/Catalog/SeedCatalog.swift")
        #expect(store.scrollRequest?.line == 1)
        #expect(!session.isPresentingComments)
    }

    @Test("An earlier revision keeps its saved excerpt and never navigates or highlights")
    func earlierRevisionNeverNavigates() async throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "Saved against the old head"
        session.save()
        let comment = try #require(commentStore.comments.first)

        var refreshed = PRReviewDemo.snapshot()
        refreshed.review.revision = 2
        refreshed.review.headSHA = "head-2"
        store.receive(refreshed)

        store.tab = .context
        store.selectedPath = "Sources/Catalog/SyncClient.swift"
        await session.showInDiff(comment, store: store)

        #expect(store.tab == .context)
        #expect(store.highlight == nil)
        #expect(store.scrollRequest == nil)
        #expect(session.navigationMessage?.contains("earlier revision") == true)
        #expect(session.locationStatus(
            for: comment,
            review: store.snapshot?.review,
            currentFilePaths: nil
        ) == .earlierRevision)
        #expect(commentStore.comment(id: comment.id)?.anchor.headSHA == "head")
    }

    @Test("A file missing from the current revision is never highlighted")
    func missingFileNeverHighlights() async throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "This file disappears"
        session.save()
        let comment = try #require(commentStore.comments.first)

        var withoutFile = PRReviewDemo.snapshot()
        withoutFile.review.revision = 2
        withoutFile.files = withoutFile.files.filter { $0.path != "Sources/Catalog/SeedCatalog.swift" }
        store.receive(withoutFile)

        let previousPath = store.selectedPath
        await session.showInDiff(comment, store: store)

        #expect(store.highlight == nil)
        #expect(store.scrollRequest == nil)
        #expect(store.selectedPath == previousPath)
        #expect(session.navigationMessage != nil)
    }

    @Test("A line absent from the loaded diff is never guessed")
    func lineNotFoundNeverHighlights() async throws {
        let store = demoStore(machineID: "machine-a")
        let commentStore = PRReviewCommentStore(inMemory: true)
        let session = PRReviewCommentsSession(store: commentStore)
        session.updateScope(from: store)
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        session.draftBody = "The second line moves away"
        session.save()
        let comment = try #require(commentStore.comments.first)

        store.diff = try narrowDiff()

        await session.showInDiff(comment, store: store)

        #expect(store.highlight == nil)
        #expect(store.scrollRequest == nil)
        #expect(session.navigationMessage?.contains("not part of the loaded diff") == true)
    }

    // MARK: - Manual GitHub handoff

    @Test("Copy and open use exact text and a PR file link without dispatching anything")
    func manualHandoffUsesInjectedBoundaries() async throws {
        let client = SyntheticPRReviewWindowClient()
        let store = PRReviewStore()
        store.configure(client: client, machineID: "machine-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        await store.refresh()
        // Synthetic hosts use a non-GitHub review origin; the manual handoff
        // only exists for real pull requests, so the fixture supplies one.
        store.snapshot?.review.url = "https://github.com/example-owner/garden-planner/pull/42"
        store.selectedPath = "Sources/Catalog/SeedCatalog.swift"
        await store.loadDiff(for: store.selectedPath)
        #expect(await client.capabilitiesCallCount == 1)
        #expect(await client.diffPaths == ["Sources/Catalog/SeedCatalog.swift"])

        let commentStore = PRReviewCommentStore(inMemory: true)
        var copied: String?
        var openedURLs: [URL] = []
        let session = PRReviewCommentsSession(
            store: commentStore,
            copyText: { copied = $0 },
            openURL: { openedURLs.append($0) }
        )
        session.updateScope(from: store)
        #expect(session.beginComposition(selection: catalogSelection(), store: store))
        let body = "  Markdown with 🧪 **bold** and trailing spaces  "
        session.draftBody = body
        session.save()
        let comment = try #require(commentStore.comments.first)

        session.copy(comment)
        #expect(copied == body)
        session.openFileInGitHub(comment)
        #expect(openedURLs.count == 1)
        let url = try #require(openedURLs.first)
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path == "/example-owner/garden-planner/pull/42/files")
        #expect(url.fragment?.hasPrefix("diff-") == true)
        #expect(!url.absoluteString.contains("bold"))
        #expect(!url.absoluteString.contains("Markdown"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.query == nil)

        // Editing is also local-only: it updates the same record without any
        // outbound request or publication status.
        session.beginEditing(comment)
        session.draftBody = "\(body)\nEdited locally"
        session.save()
        #expect(session.saveError == nil)
        #expect(commentStore.comment(id: comment.id)?.editVersion == 2)

        // Comment operations dispatch no companion, GitHub, or agent request.
        #expect(await client.capabilitiesCallCount == 1)
        #expect(await client.diffPaths == ["Sources/Catalog/SeedCatalog.swift"])
        #expect(await client.reviewIDs == [PRReviewDemo.reviewID])
        #expect(await client.downloadRequests.isEmpty)

        // No original-revision blob link is invented when the anchor has no
        // valid commit SHA, so opening stays the single PR file link above.
        session.openOriginalRevision(comment, span: comment.anchor.spans.first)
        #expect(openedURLs.count == 1)
    }

    @Test("Stored demo compositions freeze a canonical GitHub pull request URL")
    func demoStorageURLIsCanonical() {
        let demoReview = PRReviewDemo.snapshot().review
        #expect(
            PRReviewCommentsSession.storageURLString(for: demoReview, demo: true)
                == "https://github.com/example-owner/garden-planner/pull/42"
        )
        #expect(
            PRReviewCommentsSession.storageURLString(for: demoReview, demo: false)
                == "https://dev.example.test/example-owner/garden-planner/pull/42"
        )

        var real = demoReview
        real.url = "https://github.com/example-owner/garden-planner/pull/42?diff=split#discussion_r1"
        #expect(
            PRReviewCommentsSession.storageURLString(for: real, demo: false)
                == "https://github.com/example-owner/garden-planner/pull/42?diff=split#discussion_r1"
        )
    }

    // MARK: - Agent control blocking

    @Test("An open comment sheet blocks agent control as a modal")
    func openCommentSheetBlocksAgentControl() throws {
        let suite = "PRReviewCommentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shell = HerdrShellState(userDefaults: defaults)
        let commentStore = PRReviewCommentStore(inMemory: true)
        shell.attachPRReviewCommentStore(commentStore)
        let store = demoStore(machineID: "machine-a")

        #expect(shell.agentControlBlockingModal == nil)
        shell.prReviewComments.updateScope(from: store)
        shell.prReviewComments.presentList(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        #expect(shell.agentControlBlockingModal == "pr-review-comment")

        #expect(shell.prReviewComments.beginComposition(selection: catalogSelection(), store: store))
        #expect(shell.agentControlBlockingModal == "pr-review-comment")
        shell.prReviewComments.dismissCommentsSheet()
        #expect(shell.agentControlBlockingModal == nil)
    }

    // MARK: - Fixtures

    private func demoStore(machineID: String, reviewID: String = PRReviewDemo.reviewID) -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: machineID, demo: true)
        if reviewID != PRReviewDemo.reviewID {
            store.select(reviewID)
        }
        store.receive(PRReviewDemo.snapshot(for: reviewID))
        store.selectedPath = store.snapshot?.files.first?.path
        store.diff = PRReviewDemo.diff(for: reviewID)
        return store
    }

    private func catalogSelection() -> PRReviewSelection {
        PRReviewSelection(
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [.init(side: .after, start: 1, end: 2)],
            text: "import Foundation\nstruct SeedCatalog {}"
        )
    }

    private func reminderSelection() -> PRReviewSelection {
        PRReviewSelection(
            path: "Sources/Watering/ReminderSchedule.swift",
            oldPath: "",
            spans: [.init(side: .after, start: 1, end: 2)],
            text: "import Foundation\nstruct ReminderSchedule {}"
        )
    }

    private func commentAnchor() -> PRReviewCommentAnchor {
        PRReviewCommentAnchor(
            baseSHA: "base",
            headSHA: "head",
            mergeBaseSHA: nil,
            path: "Sources/Catalog/SeedCatalog.swift",
            oldPath: "",
            spans: [PRReviewCommentSpan(side: .after, start: 1, end: 2)],
            code: "import Foundation\nstruct SeedCatalog {}"
        )
    }

    private func narrowDiff() throws -> PRReviewDiff {
        let json = """
        {"ok":true,"review_id":"prr_demo42","base_sha":"base","head_sha":"head","truncated":false,"files":[
          {"path":"Sources/Catalog/SeedCatalog.swift","old_path":"","status":"modified","additions":0,"deletions":0,"binary":false,"truncated":false,"hunks":[
            {"old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"header":"@@","lines":[
              {"kind":"context","old_number":1,"new_number":1,"text":"import Foundation"}
            ]}
          ]}
        ]}
        """
        return try JSONDecoder().decode(PRReviewDiff.self, from: Data(json.utf8))
    }
}
