import Foundation
import Observation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review viewed undo")
struct PRReviewViewedUndoTests {
    private static let firstSHA = String(repeating: "c", count: 40)

    private func demoStore() -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic-host", demo: true)
        store.receive(PRReviewDemo.snapshot())
        return store
    }

    private func recordingStore(client: ViewedUndoClient) -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        return store
    }

    private func comparisonStore() throws -> (PRReviewStore, ViewedUndoClient) {
        let snapshot = PRReviewDemo.snapshot()
        let baseline = snapshot.review.mergeBaseSHA ?? snapshot.review.baseSHA
        let base = TestPRReviewClient()
        base.commitsResult = PRReviewCommits(
            reviewID: snapshot.review.id, baseSHA: snapshot.review.baseSHA, headSHA: snapshot.review.headSHA,
            baselineSHA: baseline, baselineLabel: "main",
            commits: [
                .init(sha: Self.firstSHA, parents: [baseline], subject: "Update seed catalog", authorName: "Example", authoredAt: "2026-01-01T00:00:00Z"),
                .init(sha: snapshot.review.headSHA, parents: [Self.firstSHA], subject: "Finish seed sync", authorName: "Example", authoredAt: "2026-01-02T00:00:00Z")
            ], truncated: false
        )
        base.comparisonHandler = { selection in
            var diff = PRReviewDemo.diff()
            diff.files = snapshot.files.map { metadata in
                PRReviewDiffFile(path: metadata.path, oldPath: metadata.oldPath, status: metadata.status,
                                 additions: metadata.additions, deletions: metadata.deletions,
                                 binary: false, truncated: false, hunks: [])
            }
            if selection != .all {
                diff.files = Array(diff.files.prefix(1))
                diff.files[0].path = "Sources/Historical.swift"
            }
            let before = selection.mode == .range ? selection.startCommit! : baseline
            let after = selection.mode == .all ? snapshot.review.headSHA
                : selection.mode == .commit ? selection.startCommit! : selection.endCommit!
            diff.comparison = .init(id: selection.identity, mode: selection.mode,
                                    beforeSHA: before, afterSHA: after, commitSHAs: [after])
            return diff
        }
        let client = ViewedUndoClient(base: base)
        let store = recordingStore(client: client)
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data(
            #"{"ok":true,"available":true,"capabilities":["pr-review-v1","git-comparison-v1"],"skills":[]}"#.utf8))
        return (store, client)
    }

    @Test("Marks and unmarks restore Viewed flags and progress, with redo in both directions", arguments: [true, false])
    func toggleUndoRedo(viewed: Bool) async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { $0.viewed != viewed })?.path)
        let before = store.viewedProgress

        await store.setViewedRecordingUndo(paths: [path], viewed: viewed)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == viewed)
        #expect(store.viewedProgress.viewed == before.viewed + (viewed ? 1 : -1))
        #expect(store.canUndoViewed)
        #expect(!store.canRedoViewed)

        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == !viewed)
        #expect(store.viewedProgress == before)
        #expect(!store.canUndoViewed)
        #expect(store.canRedoViewed)

        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == viewed)
        #expect(store.canUndoViewed)
        #expect(!store.canRedoViewed)
    }

    @Test("Multiple toggles undo and redo in LIFO order")
    func multiStepHistory() async throws {
        let store = demoStore()
        let paths = Array(store.comparisonFiles.filter { !$0.viewed }.prefix(2).map(\.path))
        #expect(paths.count == 2)
        let first = try #require(paths.first)
        let second = try #require(paths.last)
        let before = store.viewedProgress
        await store.setViewedRecordingUndo(paths: [first], viewed: true)
        await store.setViewedRecordingUndo(paths: [second], viewed: true)
        await store.setViewedRecordingUndo(paths: [first], viewed: false)

        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == first })?.viewed == true)
        #expect(store.viewedProgress.viewed == before.viewed + 2)
        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == second })?.viewed == false)
        #expect(store.viewedProgress.viewed == before.viewed + 1)
        await store.undoViewed()
        #expect(store.viewedProgress == before)
        #expect(!store.canUndoViewed)

        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == first })?.viewed == true)
        #expect(store.comparisonFiles.first(where: { $0.path == second })?.viewed == false)
        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == second })?.viewed == true)
        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == first })?.viewed == false)
        #expect(!store.canRedoViewed)
    }

    @Test("A new user toggle discards redo")
    func newToggleClearsRedo() async throws {
        let store = demoStore()
        let paths = Array(store.comparisonFiles.filter { !$0.viewed }.prefix(2).map(\.path))
        let first = try #require(paths.first)
        let second = try #require(paths.last)
        await store.setViewedRecordingUndo(paths: [first], viewed: true)
        await store.undoViewed()
        #expect(store.canRedoViewed)
        await store.setViewedRecordingUndo(paths: [second], viewed: true)
        #expect(!store.canRedoViewed)
        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == first })?.viewed == false)
    }

    @Test("No-op and unknown-path toggles add no history and preserve pending redo")
    func noOpToggle() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: false)
        await store.setViewedRecordingUndo(paths: ["Sources/Missing.swift"], viewed: true)
        #expect(!store.canUndoViewed)
        #expect(!store.canRedoViewed)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        await store.undoViewed()
        await store.setViewedRecordingUndo(paths: [path], viewed: false)
        #expect(!store.canUndoViewed)
        #expect(store.canRedoViewed)
    }

    @Test("Empty undo and redo do not change the snapshot or send requests")
    func emptyHistory() async {
        let client = ViewedUndoClient()
        let store = recordingStore(client: client)
        let before = store.snapshot
        let selection = store.selectedPath
        await store.undoViewed()
        await store.redoViewed()
        #expect(store.snapshot == before)
        #expect(store.selectedPath == selection)
        #expect(await client.requests.isEmpty)
    }

    @Test("History retains exactly the newest 100 steps and clears both stacks")
    func historyCapacity() {
        var history = PRReviewViewedHistory()
        let entries = (0...100).map { index in
            PRReviewViewedHistory.Entry(changes: [.init(path: "Sources/File\(index).swift", before: false)], after: true)
        }
        for entry in entries { history.record(entry) }
        for entry in entries.dropFirst().reversed() { #expect(history.takeUndo() == entry) }
        #expect(history.takeUndo() == nil)
        for entry in entries.dropFirst() { #expect(history.takeRedo() == entry) }
        #expect(history.takeRedo() == nil)
        _ = history.takeUndo()
        #expect(history.canUndo && history.canRedo)
        history.removeAll()
        #expect(history == PRReviewViewedHistory())
        #expect(history.takeUndo() == nil)
        #expect(history.takeRedo() == nil)
    }

    @Test("The store cannot undo a toggle older than its 100-step limit")
    func storeHistoryCapacity() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        for index in 0...100 {
            await store.setViewedRecordingUndo(paths: [path], viewed: index.isMultiple(of: 2))
        }
        for _ in 0..<100 { await store.undoViewed() }
        #expect(!store.canUndoViewed)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
    }

    @Test("Agent and guide Viewed changes are not recorded")
    func automatedChangesAreNotRecorded() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewed(paths: [path], viewed: true)
        #expect(!store.canUndoViewed)
        #expect(!store.canRedoViewed)
        await store.setViewed(paths: [path], viewed: false)
        var snapshot = try #require(store.snapshot)
        let index = try #require(snapshot.files.firstIndex(where: { $0.path == path }))
        snapshot.files[index].impact = .low
        store.receive(snapshot)
        let scope = PRReviewGuideScope(machineID: "synthetic-host", reviewID: snapshot.review.id,
                                       baseSHA: snapshot.review.baseSHA, headSHA: snapshot.review.headSHA)
        #expect(try await store.markBreezeViewed(path: path, scope: scope))
        #expect(!store.canUndoViewed)
        #expect(!store.canRedoViewed)
    }

    @Test("Undo and redo save restored values through the companion client", arguments: [true, false])
    func replaySavesThroughClient(viewed: Bool) async throws {
        let client = ViewedUndoClient()
        let store = recordingStore(client: client)
        let path = try #require(store.comparisonFiles.first(where: { $0.viewed != viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: viewed)
        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == !viewed)
        await store.redoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == viewed)
        let requests = await client.requests
        #expect(requests.map(\.viewed) == [viewed, !viewed, viewed])
        #expect(requests.map(\.paths) == [[path], [path], [path]])
        #expect(requests.allSatisfy { $0.reviewID == PRReviewDemo.reviewID })
    }

    @Test("Multi-path toggles restore only changed known files in one request")
    func multiPathRestore() async throws {
        let client = ViewedUndoClient()
        let store = recordingStore(client: client)
        let changed = Array(store.comparisonFiles.filter { !$0.viewed }.prefix(2).map(\.path))
        let unchanged = try #require(store.comparisonFiles.first(where: \.viewed)?.path)
        let before = store.viewedProgress
        let paths = changed + [changed[0], unchanged, "Sources/Missing.swift"]
        await store.setViewedRecordingUndo(paths: paths, viewed: true)
        let selection = store.selectedPath
        await store.undoViewed()
        #expect(store.viewedProgress == before)
        #expect(store.selectedPath == selection)
        #expect(store.comparisonFiles.first(where: { $0.path == unchanged })?.viewed == true)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests.last?.paths == changed)
        #expect(requests.last?.viewed == false)
        await store.redoViewed()
        #expect(await client.requests.last?.paths == changed)
    }

    @Test("Files absent from the current file set are skipped during undo and redo")
    func missingFilesAreSkipped() async throws {
        let client = ViewedUndoClient()
        let store = recordingStore(client: client)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        var snapshot = try #require(store.snapshot)
        snapshot.files.removeAll { $0.path == path }
        snapshot.review.revision += 1
        store.receive(snapshot)
        await store.undoViewed()
        #expect(store.canRedoViewed)
        await store.redoViewed()
        #expect(await client.requests.count == 1)
        #expect(!store.comparisonFiles.contains(where: { $0.path == path }))
    }

    @Test("Commit and range marks undo and redo locally without companion saves", arguments: [false, true])
    func comparisonLocalHistory(range: Bool) async throws {
        let (store, client) = try comparisonStore()
        await store.loadComparison()
        let listing = try #require(store.comparisonCommits)
        let wholePR = store.viewedProgress
        store.selectComparison(before: range ? Self.firstSHA : listing.baselineSHA,
                               after: range ? listing.headSHA : Self.firstSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection.mode == (range ? .range : .commit))
        let path = try #require(store.comparisonFiles.first?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        #expect(store.viewedProgress.isComplete)
        await store.undoViewed()
        #expect(store.comparisonFiles.first?.viewed == false)
        await store.redoViewed()
        #expect(store.comparisonFiles.first?.viewed == true)
        await store.setViewedRecordingUndo(paths: [path], viewed: false)
        await store.undoViewed()
        #expect(store.comparisonFiles.first?.viewed == true)
        await store.redoViewed()
        #expect(store.comparisonFiles.first?.viewed == false)
        #expect(await client.requests.isEmpty)
        #expect(PRReviewViewedProgress(files: store.snapshot?.files ?? []) == wholePR)
    }

    @Test("Host, review, and content revision changes clear both history stacks", arguments: ["select", "configure", "reconnect-host", "base", "head"])
    func scopeChangesClearHistory(change: String) async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        await store.setViewedRecordingUndo(paths: [path], viewed: false)
        await store.undoViewed()
        #expect(store.canUndoViewed && store.canRedoViewed)
        switch change {
        case "select": store.select(PRReviewDemo.secondReviewID)
        case "configure": store.configure(client: nil, machineID: "synthetic-other", demo: true)
        case "reconnect-host": store.reconnect(client: nil, machineID: "synthetic-other", demo: true)
        default:
            var snapshot = try #require(store.snapshot)
            snapshot.review.revision += 1
            if change == "base" { snapshot.review.baseSHA = String(repeating: "d", count: 40) }
            else { snapshot.review.headSHA = String(repeating: "e", count: 40) }
            store.receive(snapshot)
        }
        #expect(!store.canUndoViewed)
        #expect(!store.canRedoViewed)
    }

    @Test("Same-host reconnects and metadata-only polls retain history")
    func unchangedScopeRetainsHistory() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        let history = store.viewedHistory
        store.reconnect(client: nil, machineID: "synthetic-host", demo: true)
        var snapshot = try #require(store.snapshot)
        snapshot.review.revision += 1
        store.receive(snapshot)
        #expect(store.viewedHistory == history)
        await store.undoViewed()
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == false)
    }

    @Test("Changing comparisons clears history while selecting the current comparison preserves it")
    func comparisonChangesClearHistory() async throws {
        let (store, _) = try comparisonStore()
        await store.loadComparison()
        let listing = try #require(store.comparisonCommits)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        store.selectComparison(before: listing.baselineSHA, after: listing.headSHA)
        #expect(store.canUndoViewed)
        store.selectComparison(before: listing.baselineSHA, after: Self.firstSHA)
        #expect(!store.canUndoViewed && !store.canRedoViewed)
        await store.loadComparison()
        let historicalPath = try #require(store.comparisonFiles.first?.path)
        await store.setViewedRecordingUndo(paths: [historicalPath], viewed: true)
        await store.undoViewed()
        #expect(store.canRedoViewed)
        store.selectComparison(before: Self.firstSHA, after: listing.headSHA)
        #expect(!store.canUndoViewed && !store.canRedoViewed)
    }

    @Test("Restoring a comparison and rejecting its revision seed clear history")
    func comparisonSeedsClearHistory() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        store.snapshot = nil
        store.restoreComparisonSelection(.init(mode: .commit, startCommit: Self.firstSHA),
                                         baseSHA: "synthetic-base", headSHA: "synthetic-head")
        #expect(!store.canUndoViewed && !store.canRedoViewed)
        store.receive(PRReviewDemo.snapshot())
        #expect(store.comparisonSelection == .all)
        #expect(!store.canUndoViewed && !store.canRedoViewed)
    }

    @Test("A single restored file is selected only when it matches the current filters")
    func selectionFollowsRestoredFile() async throws {
        let store = demoStore()
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        let other = try #require(store.comparisonFiles.first(where: { $0.path != path && !$0.viewed })?.path)
        store.hideViewed = true
        await store.setViewedRecordingUndo(paths: [path], viewed: true)
        store.selectedPath = path
        store.normalizeSelectedFile()
        #expect(store.selectedPath != path)
        await store.undoViewed()
        #expect(store.selectedPath == path)
        await store.redoViewed()
        store.normalizeSelectedFile()
        #expect(store.selectedPath != path)
        store.search = other
        store.normalizeSelectedFile()
        await store.undoViewed()
        #expect(store.selectedPath == other)
        store.hideViewed = false
        store.search = ""
        store.selectedPath = other
        await store.redoViewed()
        #expect(store.selectedPath == path)
    }

    @Test("Main and popped-out stores have independent histories")
    func independentStores() async throws {
        let first = demoStore()
        let second = demoStore()
        let path = try #require(first.comparisonFiles.first(where: { !$0.viewed })?.path)
        await first.setViewedRecordingUndo(paths: [path], viewed: true)
        #expect(first.canUndoViewed)
        #expect(!second.canUndoViewed && !second.canRedoViewed)
        await second.undoViewed()
        #expect(first.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
        await second.setViewedRecordingUndo(paths: [path], viewed: true)
        await first.undoViewed()
        #expect(first.canRedoViewed)
        #expect(second.canUndoViewed && !second.canRedoViewed)
        #expect(second.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
    }

    @Test("Quick toggle, undo, and redo save in order without losing optimistic state to responses or polling")
    func overlappingUndoRedo() async throws {
        let client = ViewedUndoClient(holdResponses: true)
        let store = recordingStore(client: client)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        let toggle = Task { await store.setViewedRecordingUndo(paths: [path], viewed: true) }
        await client.waitForRequest(1)
        let undo = Task { await store.undoViewed() }
        await waitForViewed(false, path: path, store: store)

        var poll = try #require(store.snapshot)
        poll.review.revision += 1
        let index = try #require(poll.files.firstIndex(where: { $0.path == path }))
        poll.files[index].viewed = true
        poll.files[index].impactReason = "New ranking from an agent event"
        store.receive(poll)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == false)

        await client.completeRequest(1)
        await client.waitForRequest(2)
        await toggle.value
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == false)
        #expect(store.snapshot?.files[index].impactReason == "New ranking from an agent event")
        let redo = Task { await store.redoViewed() }
        await waitForViewed(true, path: path, store: store)
        await client.completeRequest(2)
        await client.waitForRequest(3)
        await undo.value
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
        await client.completeRequest(3)
        await redo.value

        #expect(await client.requests.map(\.viewed) == [true, false, true])
        #expect(await client.maximumInFlight == 1)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
        #expect(store.canUndoViewed && !store.canRedoViewed)
    }

    @Test("Obsolete Viewed responses and queued undo cannot alter a new scope", arguments:
        ["base", "head", "review", "review-roundtrip", "reconnect", "host", "invalidate"], [false, true])
    func staleViewedWrites(change: String, fails: Bool) async throws {
        let client = ViewedUndoClient(holdResponses: true)
        let store = recordingStore(client: client)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        let toggle = Task { await store.setViewedRecordingUndo(paths: [path], viewed: true) }
        await client.waitForRequest(1)
        let undo = Task { await store.undoViewed() }
        await waitForViewed(false, path: path, store: store)

        var next = PRReviewDemo.snapshot()
        next.review.revision += 1
        switch change {
        case "base": next.review.baseSHA = String(repeating: "d", count: 40)
        case "head": next.review.headSHA = String(repeating: "e", count: 40)
        case "review":
            next.review.id = PRReviewDemo.secondReviewID
            store.select(next.review.id)
        case "review-roundtrip":
            store.select(PRReviewDemo.secondReviewID)
            store.select(next.review.id)
        case "reconnect": store.reconnect(client: client, machineID: "synthetic-host", demo: false)
        case "host":
            store.configure(client: client, machineID: "synthetic-other", demo: false)
            store.select(next.review.id)
        default: store.invalidateConnection()
        }
        next.files[0].impactReason = "Current revision metadata"
        store.receive(next)
        store.selectedPath = next.files.last?.path
        let selected = store.selectedPath
        store.error = "Current scope notice"
        let expected = store.snapshot

        await client.completeRequest(1, fails: fails)
        await toggle.value
        await undo.value
        #expect(await client.requests.count == 1, "The old queued undo must never be sent")
        #expect(store.snapshot == expected)
        #expect(store.selectedPath == selected)
        #expect(store.error == "Current scope notice")
    }

    @Test("A save after reconnect waits for the old transport, while obsolete queued writes retire")
    func reconnectWriteOrdering() async throws {
        let firstClient = ViewedUndoClient(holdResponses: true)
        let nextClient = ViewedUndoClient(holdResponses: true)
        let store = recordingStore(client: firstClient)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        let toggle = Task { await store.setViewedRecordingUndo(paths: [path], viewed: true) }
        await firstClient.waitForRequest(1)
        let undo = Task { await store.undoViewed() }
        await waitForViewed(false, path: path, store: store)
        store.reconnect(client: nextClient, machineID: "synthetic-host", demo: false)
        let next = Task { await store.setViewedRecordingUndo(paths: [path], viewed: true) }
        await waitForViewed(true, path: path, store: store)
        #expect(await nextClient.requests.isEmpty)
        await firstClient.completeRequest(1)
        await nextClient.waitForRequest(1)
        await toggle.value
        await undo.value
        #expect(await firstClient.requests.count == 1)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
        await nextClient.completeRequest(1)
        await next.value
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == true)
    }

    @Test("A failed save keeps its error and lets a queued undo proceed")
    func failedWriteDoesNotBlockUndo() async throws {
        let client = ViewedUndoClient(holdResponses: true)
        let store = recordingStore(client: client)
        let path = try #require(store.comparisonFiles.first(where: { !$0.viewed })?.path)
        let toggle = Task { await store.setViewedRecordingUndo(paths: [path], viewed: true) }
        await client.waitForRequest(1)
        let undo = Task { await store.undoViewed() }
        await waitForViewed(false, path: path, store: store)
        await client.completeRequest(1, fails: true)
        await client.waitForRequest(2)
        await toggle.value
        #expect(store.error?.contains("Synthetic Viewed save failed") == true)
        #expect(store.comparisonFiles.first(where: { $0.path == path })?.viewed == false)
        await client.completeRequest(2)
        await undo.value
        #expect(await client.maximumInFlight == 1)
        #expect(store.canRedoViewed && !store.canUndoViewed)
    }

    private func waitForViewed(_ viewed: Bool, path: String, store: PRReviewStore) async {
        while store.comparisonFiles.first(where: { $0.path == path })?.viewed != viewed {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = store.comparisonFiles
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

private actor ViewedUndoClient: PRReviewClient {
    struct Request: Equatable, Sendable {
        let reviewID: String
        let paths: [String]
        let viewed: Bool
    }

    private let base: TestPRReviewClient
    private let holdResponses: Bool
    private var files = PRReviewDemo.snapshot().files
    private(set) var requests: [Request] = []
    private var pendingResponses: [Int: (files: [PRReviewFile], continuation: CheckedContinuation<[PRReviewFile], any Error>)] = [:]
    private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var maximumInFlight = 0

    init(base: TestPRReviewClient = TestPRReviewClient(), holdResponses: Bool = false) {
        self.base = base
        self.holdResponses = holdResponses
    }

    func setPRReviewViewed(id: String, paths: [String], viewed: Bool, requestID: String) async throws -> [PRReviewFile] {
        requests.append(.init(reviewID: id, paths: paths, viewed: viewed))
        for index in files.indices where paths.contains(files[index].path) { files[index].viewed = viewed }
        if holdResponses {
            return try await withCheckedThrowingContinuation { continuation in
                pendingResponses[requests.count] = (files, continuation)
                maximumInFlight = max(maximumInFlight, pendingResponses.count)
                for waiter in requestWaiters.removeValue(forKey: requests.count) ?? [] { waiter.resume() }
            }
        }
        return files
    }

    func waitForRequest(_ number: Int) async {
        guard requests.count < number else { return }
        await withCheckedContinuation { requestWaiters[number, default: []].append($0) }
    }

    func completeRequest(_ number: Int, fails: Bool = false) {
        guard let response = pendingResponses.removeValue(forKey: number) else { return }
        if fails {
            response.continuation.resume(throwing: APIError.server(status: 503, message: "Synthetic Viewed save failed"))
        } else {
            response.continuation.resume(returning: response.files)
        }
    }

    func prReviewCapabilities() async throws -> PRReviewCapabilities { try await base.prReviewCapabilities() }
    func prReviewSkills() async throws -> [PRReviewSkill] { try await base.prReviewSkills() }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { try await base.addPRReviewSkill(body) }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { try await base.removePRReviewSkill(id: id, requestID: requestID) }
    func prReviews(scope: String) async throws -> [PRReviewSummary] { try await base.prReviews(scope: scope) }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot { try await base.createPRReview(url: url, skillIDs: skillIDs, requestID: requestID) }
    func prReview(id: String) async throws -> PRReviewSnapshot { try await base.prReview(id: id) }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot { try await base.refreshPRReview(id: id, requestID: requestID) }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot { try await base.archivePRReview(id: id, archived: archived, requestID: requestID) }
    func prReviewCommits(id: String, baseSHA: String, headSHA: String) async throws -> PRReviewCommits { try await base.prReviewCommits(id: id, baseSHA: baseSHA, headSHA: headSHA) }
    func prReviewDiff(id: String, path: String?, comparison: GitComparisonSelection, baseSHA: String, headSHA: String) async throws -> PRReviewDiff {
        try await base.prReviewDiff(id: id, path: path, comparison: comparison, baseSHA: baseSHA, headSHA: headSHA)
    }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { try await base.prReviewDiff(id: id, path: path) }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText {
        try await base.prReviewFileText(id: id, path: path, side: side, start: start, end: end)
    }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { try await base.prReviewFindings(id: id, path: path) }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun { try await base.createPRReviewRun(id: id, skillID: skillID, requestID: requestID) }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { try await base.prReviewRun(reviewID: reviewID, runID: runID) }
    func finishPRReviewRun(reviewID: String, runID: String, state: PRReviewRunState, note: String?, requestID: String) async throws -> PRReviewRun {
        try await base.finishPRReviewRun(reviewID: reviewID, runID: runID, state: state, note: note, requestID: requestID)
    }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { try await base.prReviewRunOutput(reviewID: reviewID, runID: runID, lines: lines) }
    func markPRReviewSkill(reviewID: String, skillID: String, state: String, note: String?, requestID: String) async throws -> PRReviewSkillState {
        try await base.markPRReviewSkill(reviewID: reviewID, skillID: skillID, state: state, note: note, requestID: requestID)
    }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary { try await base.rankPRReview(id: id, requestID: requestID) }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { try await base.setPRReviewRankings(id: id, files: files, requestID: requestID) }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { try await base.syncPRReviewViewed(id: id, requestID: requestID) }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { try await base.prReviewDocuments(id: id) }
    func addPRReviewDocument(id: String, payload: PRReviewDocumentPayload, requestID: String) async throws -> PRReviewDocument { try await base.addPRReviewDocument(id: id, payload: payload, requestID: requestID) }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument { try await base.prReviewDocument(reviewID: reviewID, documentID: documentID) }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws {
        try await base.downloadPRReviewDocument(reviewID: reviewID, documentID: documentID, expectedByteSize: expectedByteSize, to: destinationURL)
    }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { try await base.prReviewEvents(id: id, after: after) }
}
