import AppKit
import SwiftUI
import AVFoundation
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR review comparisons", .serialized)
struct PRReviewComparisonTests {
    private static let firstSHA = String(repeating: "c", count: 40)

    private func configured(gate: ComparisonResponseGate? = nil, testClient: TestPRReviewClient? = nil) throws -> PRReviewStore {
        let snapshot = PRReviewDemo.snapshot()
        let baseline = snapshot.review.mergeBaseSHA ?? snapshot.review.baseSHA
        let client = testClient ?? TestPRReviewClient()
        client.commitsResult = PRReviewCommits(reviewID: snapshot.review.id,
            baseSHA: snapshot.review.baseSHA, headSHA: snapshot.review.headSHA,
            baselineSHA: baseline, baselineLabel: "main",
            commits: [
                .init(sha: Self.firstSHA, parents: [baseline], subject: "Add temporary file", authorName: "Example", authoredAt: "2026-01-01T00:00:00Z"),
                .init(sha: snapshot.review.headSHA, parents: [Self.firstSHA], subject: "Remove temporary file", authorName: "Example", authoredAt: "2026-01-02T00:00:00Z")
            ], truncated: false)
        client.comparisonHandler = { selection in
            if selection.mode == .commit, let gate { await gate.wait() }
            var diff = PRReviewDemo.diff()
            // The demo patch contains four render samples while the snapshot
            // lists ten files. This endpoint fixture returns a complete set.
            diff.files = snapshot.files.map { metadata in
                diff.files.first(where: { $0.path == metadata.path }) ?? PRReviewDiffFile(
                    path: metadata.path, oldPath: metadata.oldPath, status: metadata.status,
                    additions: metadata.additions, deletions: metadata.deletions,
                    binary: false, truncated: false, hunks: [])
            }
            let before = selection.mode == .range ? selection.startCommit! : baseline
            let after = selection.mode == .all ? snapshot.review.headSHA : selection.mode == .commit ? selection.startCommit! : selection.endCommit!
            diff.comparison = .init(id: selection.identity, mode: selection.mode, beforeSHA: before, afterSHA: after, commitSHAs: [after])
            if selection.mode != .all {
                var file = diff.files[0]
                file.path = "Sources/Temporary.swift"
                file.status = selection.mode == .commit ? "added" : "deleted"
                diff.files = [file]
            }
            return diff
        }
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(snapshot.review.id)
        store.receive(snapshot)
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self,
            from: Data(#"{"ok":true,"available":true,"capabilities":["pr-review-v1","git-comparison-v1","pr-review-guide-v1"],"skills":[]}"#.utf8))
        client.capabilitiesResult = store.capabilities
        return store
    }

    @Test("Comparison-enabled minimum window keeps its revision controls and code usable")
    func comparisonEnabledMinimumWindow() async throws {
        let store = try configured()
        await store.loadComparison()
        #expect(store.supportsComparisons)
        #expect(store.comparisonCommits?.commits.count == 2)
        let size = CGSize(width: 720, height: 520)
        let hosting = NSHostingView(rootView:
            PRReviewContainerView(store: store)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if descendants(hosting).compactMap({ $0 as? PRReviewDiffTextView }).first?.renderedIdentity != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let split = try #require(descendants(hosting).compactMap { $0 as? NSSplitView }.first)
        let rail = try #require(split.arrangedSubviews.first)
        let textView = try #require(descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first)
        let railRect = rail.convert(rail.bounds, to: hosting)
        let codeRect = textView.convert(textView.bounds, to: hosting)
        #expect(railRect.width >= PRReviewFilesLayout.minimumRailWidth - 1)
        #expect(codeRect.width >= PRReviewFilesLayout.minimumDiffWidth - 1)
        #expect(codeRect.height > size.height * 0.5)
        #expect(split.frame.height > size.height * 0.55)
        #expect(textView.renderedPlainText.contains("struct SeedCatalog {}"))
        // The hosted SwiftUI view has no accessibility children in this test harness.
        // Keep the capability-enabled render artifact for visual control verification.
        let result = try await HerdrRenderHarness.render("pr-review-comparison-minimum.png", size: size, settlePasses: 12) {
            PRReviewContainerView(store: store)
        }
        result.expectSubstantial()
    }

    @Test("Historical comparison has its own complete file set and Viewed flags")
    func historicalFilesAndViewed() async throws {
        let store = try configured()
        await store.loadComparison()
        let listing = try #require(store.comparisonCommits)
        store.selectComparison(before: listing.baselineSHA, after: Self.firstSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection.mode == .commit)
        #expect(store.orderedFiles.map(\.path) == ["Sources/Temporary.swift"])
        #expect(store.currentDiff?.baseSHA == store.snapshot?.review.baseSHA)
        #expect(store.currentComparison?.afterSHA == Self.firstSHA)
        #expect(!store.guide.isStale)
        await store.setViewed(paths: ["Sources/Temporary.swift"], viewed: true)
        #expect(store.comparisonFiles.first?.viewed == true)
        #expect(store.snapshot?.files.contains(where: { $0.path == "Sources/Temporary.swift" }) == false)
        store.selectComparison(before: listing.baselineSHA, after: listing.headSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection == .all)
        #expect(store.comparisonFiles.map(\.path) == store.snapshot?.files.map(\.path))
    }

    @Test("Late commit response cannot overwrite a newer tree comparison")
    func lateComparisonResponse() async throws {
        let gate = ComparisonResponseGate()
        let store = try configured(gate: gate)
        await store.loadComparison()
        let listing = try #require(store.comparisonCommits)
        store.selectComparison(before: listing.baselineSHA, after: Self.firstSHA)
        let pending = Task { await store.loadComparison() }
        await gate.waitUntilEntered()
        store.selectComparison(before: Self.firstSHA, after: listing.headSHA)
        await store.loadComparison()
        await gate.release()
        await pending.value
        #expect(store.currentComparison?.mode == .range)
        #expect(store.currentComparison?.beforeSHA == Self.firstSHA)
        #expect(store.comparisonFiles.first?.status == "deleted")
        #expect(!store.isLoadingComparison)
        #expect(store.guide.scope?.comparison == store.currentComparison)
    }

    @Test("Reversed or equal endpoints preserve the selected comparison")
    func orderedEndpoints() async throws {
        let store = try configured()
        await store.loadComparison()
        let listing = try #require(store.comparisonCommits)
        store.selectComparison(before: listing.headSHA, after: Self.firstSHA)
        #expect(store.comparisonSelection == .all)
        store.selectComparison(before: Self.firstSHA, after: Self.firstSHA)
        #expect(store.comparisonSelection == .all)
    }

    @Test("Merged branch commits are selectable but sibling ranges cannot flip history")
    func mergedHistoryAncestry() {
        func commit(_ sha: String, _ parents: [String]) -> GitCommit {
            .init(sha: sha, parents: parents, subject: sha, authorName: "Example", authoredAt: "2026-01-01T00:00:00Z")
        }
        let commits = [commit("left", ["base"]), commit("right", ["base"]), commit("merge", ["left", "right"])]
        let listing = PRReviewCommits(reviewID: "example", baseSHA: "base", headSHA: "merge", baselineSHA: "base", baselineLabel: "main", commits: commits, truncated: false)
        #expect(listing.allows(before: "base", after: "right"))
        #expect(listing.allows(before: "right", after: "merge"))
        #expect(!listing.allows(before: "left", after: "right"))
        #expect(!listing.allows(before: "merge", after: "left"))
    }

    @Test("Pop-outs preserve historical selection during loading and reject changed-revision seeds", arguments: [false, true])
    func windowSeedComparison(changedRevision: Bool) async throws {
        let source = try configured()
        await source.loadComparison()
        let listing = try #require(source.comparisonCommits)
        source.selectComparison(before: listing.baselineSHA, after: Self.firstSHA)
        await source.loadComparison()
        source.diffStyle = "split"; source.diffOverflow = "wrap"
        let target = PRReviewWindowTarget(machineID: "synthetic-host", reviewID: listing.reviewID)
        var seed = try #require(PRReviewWindowSeed.capture(from: source, target: target))
        if changedRevision { seed.comparisonHeadSHA = "earlier" }
        let gate = ComparisonResponseGate()
        let client = TestPRReviewClient()
        _ = try configured(gate: gate, testClient: client)
        let window = PRReviewWindowSession(target: target)
        await window.activate(identity: "synthetic", hostState: .available, client: client, seed: seed)
        defer { window.stop() }
        #expect(window.store.diffStyle == "split")
        #expect(window.store.diffOverflow == "wrap")
        window.store.normalizeSelectedFile()
        if changedRevision {
            #expect(window.store.comparisonSelection == .all)
            #expect(window.store.selectedPath != "Sources/Temporary.swift")
        } else {
            #expect(window.store.comparisonSelection.mode == .commit)
            #expect(window.store.selectedPath == "Sources/Temporary.swift")
            let loading = Task { await window.store.loadComparison() }
            await gate.waitUntilEntered()
            window.store.normalizeSelectedFile()
            #expect(window.store.selectedPath == "Sources/Temporary.swift")
            await gate.release()
            await loading.value
            window.store.normalizeSelectedFile()
            #expect(window.store.selectedPath == "Sources/Temporary.swift")
            #expect(window.store.currentComparison?.afterSHA == Self.firstSHA)
        }
    }

    @Test("Guide wire request preserves revision selectors and visible-line state")
    func guideRequest() throws {
        let request = PRReviewGuideRequest(requestID: "synthetic", baseSHA: "base", headSHA: "head",
            kind: "answer", question: "Why this change?", path: "Example.swift", chapterID: nil,
            continueFromGuideID: nil, selection: nil,
            comparison: .init(mode: .range, startCommit: "older", endCommit: "newer"),
            viewerState: .init(path: "Example.swift", visibleLines: .init(path: "Example.swift", side: "old", startLine: 3, endLine: 8), diffStyle: "split", overflow: "wrap"))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let comparison = try #require(json["comparison"] as? [String: String])
        #expect(comparison == ["mode": "range", "start_commit": "older", "end_commit": "newer"])
        let viewer = try #require(json["viewer_state"] as? [String: Any])
        #expect(viewer["diff_style"] as? String == "split")
        #expect((viewer["visible_lines"] as? [String: Any])?["start_line"] as? Int == 3)
    }

    @Test("Breeze cannot mark a file merely because preparation or a paused callback completed")
    func breezeInterruption() async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic-host", demo: true)
        var snapshot = PRReviewDemo.snapshot()
        snapshot.files[0].impact = .low
        snapshot.files[0].viewed = false
        store.receive(snapshot)
        let session = store.guide
        session.configure(store: store)
        #expect(session.canStartBreeze)
        session.startBreeze()
        session.pause()
        for _ in 0..<200 where session.isBusy { await Task.yield() }
        session.player.onCompletion?()
        #expect(store.snapshot?.files[0].viewed == false)
        #expect(session.breezePaused)
        session.stopBreeze()
        #expect(!session.isBreezing)
    }

    @Test("Breeze advances only after completed audio and a confirmed Viewed save", arguments: ["complete", "paused", "save-failed"])
    func breezeCompletion(outcome: String) async throws {
        let client = TestPRReviewClient()
        var snapshot = PRReviewDemo.snapshot()
        for index in snapshot.files.indices { snapshot.files[index].impact = index == 0 ? .low : .high; snapshot.files[index].viewed = false }
        let files = snapshot.files
        client.viewedHandler = { paths in
            if outcome == "save-failed" { throw APIError.server(status: 503, message: "Synthetic save unavailable") }
            return files.map { file in var file = file; if paths.contains(file.path) { file.viewed = true }; return file }
        }
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(snapshot.review.id); store.receive(snapshot)
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data(#"{"ok":true,"available":true,"capabilities":["pr-review-v1","pr-review-guide-v1"],"skills":[]}"#.utf8))
        let session = store.guide
        session.configure(store: store)
        let engine = BreezeAudioEngine()
        session.player.makePlayer = { _ in engine }
        session.startBreeze()
        for _ in 0..<200 where !session.isPlaying { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isPlaying)
        #expect(store.snapshot?.files[0].viewed == false)
        if outcome == "paused" { session.pause() }
        session.player.finishForTesting()
        for _ in 0..<200 where session.isSavingBreeze { await Task.yield() }
        #expect(store.snapshot?.files[0].viewed == (outcome == "complete"))
        if outcome == "complete" { #expect(!session.isBreezing) }
        else { #expect(session.breezePaused) }
        if outcome == "save-failed" { #expect(session.error?.contains("Viewed could not be saved") == true) }
        session.suspend()
    }

    @Test("Breeze saves only a matching full-PR revision after an explicit completion")
    func breezeRevisionGuard() async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "synthetic-host", demo: true)
        var snapshot = PRReviewDemo.snapshot()
        snapshot.files[0].impact = .low
        snapshot.files[0].viewed = false
        store.receive(snapshot)
        let scope = PRReviewGuideScope(machineID: "synthetic-host", reviewID: snapshot.review.id,
            baseSHA: snapshot.review.baseSHA, headSHA: snapshot.review.headSHA)
        var stale = scope
        stale.headSHA = "earlier"
        #expect(try await store.markBreezeViewed(path: snapshot.files[0].path, scope: stale) == false)
        #expect(store.snapshot?.files[0].viewed == false)
        #expect(try await store.markBreezeViewed(path: snapshot.files[0].path, scope: scope))
        #expect(store.snapshot?.files[0].viewed == true)
    }
}

private actor ComparisonResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class BreezeAudioEngine: PRReviewAudioEngine {
    var delegate: (any AVAudioPlayerDelegate)?
    var currentTime = 0.0
    var duration = 1.0
    var enableRate = false
    var rate: Float = 1
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}
