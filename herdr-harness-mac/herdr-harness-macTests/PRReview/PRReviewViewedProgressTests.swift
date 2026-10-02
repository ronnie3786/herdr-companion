import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review viewed progress")
struct PRReviewViewedProgressTests {
    @Test("An empty file list has zero progress and is not complete")
    func emptyProgress() {
        let progress = PRReviewViewedProgress(files: [])

        #expect(progress.total == 0)
        #expect(progress.viewed == 0)
        #expect(progress.unviewed == 0)
        #expect(!progress.isComplete)
        #expect(progress.fraction == 0)
        #expect(progress.summary == "0 of 0 viewed · 0 unviewed")
        #expect(progress.accessibilityLabel == "Review progress")
        #expect(progress.accessibilityValue == "0 of 0 files viewed, 0 remaining")
    }

    @Test("A review with no viewed files reports every file as unviewed")
    func unstartedProgress() {
        let files = PRReviewDemo.snapshot().files.map { file in
            var file = file
            file.viewed = false
            return file
        }
        let progress = PRReviewViewedProgress(files: files)

        #expect(progress.total == files.count)
        #expect(progress.viewed == 0)
        #expect(progress.unviewed == files.count)
        #expect(!progress.isComplete)
        #expect(progress.fraction == 0)
        #expect(progress.summary == "0 of \(files.count) viewed · \(files.count) unviewed")
        #expect(progress.accessibilityValue == "0 of \(files.count) files viewed, \(files.count) remaining")
    }

    @Test("The demo snapshot counts Viewed flags across all changed files")
    func partialProgress() {
        let files = PRReviewDemo.snapshot().files
        let viewed = files.filter(\.viewed).count
        let unviewed = files.count - viewed
        let progress = PRReviewViewedProgress(files: files)

        #expect(viewed > 0 && unviewed > 0)
        #expect(progress.total == files.count)
        #expect(progress.viewed == viewed)
        #expect(progress.unviewed == unviewed)
        #expect(!progress.isComplete)
        #expect(progress.fraction == Double(viewed) / Double(files.count))
        #expect(progress.summary == "\(viewed) of \(files.count) viewed · \(unviewed) unviewed")
        #expect(progress.accessibilityValue == "\(viewed) of \(files.count) files viewed, \(unviewed) remaining")
        #expect(progress == PRReviewViewedProgress(files: Array(files.reversed())))
    }

    @Test("A single-file review uses singular completion and accessibility copy", arguments: [false, true])
    func singleFileProgress(viewed: Bool) {
        var file = PRReviewDemo.snapshot().files[0]
        file.viewed = viewed
        let progress = PRReviewViewedProgress(files: [file])

        #expect(progress.total == 1)
        #expect(progress.viewed == (viewed ? 1 : 0))
        #expect(progress.unviewed == (viewed ? 0 : 1))
        #expect(progress.isComplete == viewed)
        #expect(progress.fraction == (viewed ? 1 : 0))
        #expect(progress.summary == (viewed ? "1 of 1 file viewed" : "0 of 1 viewed · 1 unviewed"))
        #expect(progress.accessibilityValue == (viewed
            ? "1 of 1 file viewed, 0 remaining"
            : "0 of 1 file viewed, 1 remaining"))
    }

    @Test("A completed review names the full file count")
    func completeProgress() {
        let files = PRReviewDemo.snapshot().files.map { file in
            var file = file
            file.viewed = true
            return file
        }
        let progress = PRReviewViewedProgress(files: files)

        #expect(progress.total == files.count)
        #expect(progress.viewed == files.count)
        #expect(progress.unviewed == 0)
        #expect(progress.isComplete)
        #expect(progress.fraction == 1)
        #expect(progress.summary == "All \(files.count) files viewed")
        #expect(progress.accessibilityValue == "\(files.count) of \(files.count) files viewed, 0 remaining")
    }

    @Test("Viewed progress updates optimistically before the request finishes")
    func setViewedIsOptimistic() async throws {
        let client = TestPRReviewClient(delay: .milliseconds(40))
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.receive(PRReviewDemo.snapshot())
        let path = try #require(store.snapshot?.files.first(where: { !$0.viewed })?.path)
        let before = store.viewedProgress
        var requestFinished = false

        let request = Task {
            await store.setViewed(paths: [path], viewed: true)
            requestFinished = true
        }
        await Task.yield()

        #expect(!requestFinished)
        #expect(store.viewedProgress.total == before.total)
        #expect(store.viewedProgress.viewed == before.viewed + 1)
        #expect(store.viewedProgress.unviewed == before.unviewed - 1)
        await request.value
    }

    @Test("Impact, Hide viewed, and text filters never change review progress")
    func filterIndependence() {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.receive(PRReviewDemo.snapshot())
        let before = store.viewedProgress

        store.impactFilter = .high
        #expect(store.orderedFiles.count < before.total)
        #expect(store.viewedProgress == before)

        store.impactFilter = .all
        store.hideViewed = true
        #expect(store.orderedFiles.count == before.unviewed)
        #expect(store.viewedProgress == before)

        store.hideViewed = false
        store.search = PRReviewDemo.snapshot().files[0].path
        #expect(store.orderedFiles.count == 1)
        #expect(store.viewedProgress == before)

        store.impactFilter = .low
        store.hideViewed = true
        #expect(store.orderedFiles.isEmpty)
        #expect(store.viewedProgress == before)
    }

    @Test("Snapshot refreshes and marking unviewed recompute progress")
    func progressFollowsViewedChanges() async {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        var snapshot = PRReviewDemo.snapshot()
        for index in snapshot.files.indices { snapshot.files[index].viewed = true }
        snapshot.review.revision += 1
        store.receive(snapshot)
        #expect(store.viewedProgress.isComplete)

        await store.setViewed(paths: [snapshot.files[0].path], viewed: false)
        #expect(store.viewedProgress.unviewed == 1)
        #expect(!store.viewedProgress.isComplete)

        snapshot.review.revision += 1
        store.receive(snapshot)
        #expect(store.viewedProgress.isComplete)
        #expect(store.viewedProgress.unviewed == 0)
    }

    @Test("Commit and range comparisons count their own local Viewed marks")
    func comparisonProgressUsesLocalMarks() async throws {
        let snapshot = PRReviewDemo.snapshot()
        let baseline = snapshot.review.mergeBaseSHA ?? snapshot.review.baseSHA
        let firstSHA = String(repeating: "c", count: 40)
        let client = TestPRReviewClient()
        client.commitsResult = PRReviewCommits(
            reviewID: snapshot.review.id,
            baseSHA: snapshot.review.baseSHA,
            headSHA: snapshot.review.headSHA,
            baselineSHA: baseline,
            baselineLabel: "main",
            commits: [
                .init(sha: firstSHA, parents: [baseline], subject: "Update seed catalog", authorName: "Example", authoredAt: "2026-01-01T00:00:00Z"),
                .init(sha: snapshot.review.headSHA, parents: [firstSHA], subject: "Finish seed sync", authorName: "Example", authoredAt: "2026-01-02T00:00:00Z")
            ],
            truncated: false
        )
        client.comparisonHandler = { selection in
            var diff = PRReviewDemo.diff()
            if selection == .all {
                // The demo diff has render samples, not the snapshot's full file set.
                diff.files = snapshot.files.map { metadata in
                    diff.files.first(where: { $0.path == metadata.path }) ?? PRReviewDiffFile(
                        path: metadata.path, oldPath: metadata.oldPath, status: metadata.status,
                        additions: metadata.additions, deletions: metadata.deletions,
                        binary: false, truncated: false, hunks: [])
                }
            } else {
                diff.files = Array(diff.files.prefix(1))
            }
            let before = selection.mode == .range ? selection.startCommit! : baseline
            let after = selection.mode == .all ? snapshot.review.headSHA
                : selection.mode == .commit ? selection.startCommit! : selection.endCommit!
            diff.comparison = .init(id: selection.identity, mode: selection.mode,
                                    beforeSHA: before, afterSHA: after, commitSHAs: [after])
            return diff
        }
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-host", demo: false)
        store.select(snapshot.review.id)
        store.receive(snapshot)
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data(
            #"{"ok":true,"available":true,"capabilities":["pr-review-v1","git-comparison-v1"],"skills":[]}"#.utf8))
        await store.loadComparison()
        let wholePR = store.viewedProgress
        #expect(wholePR == PRReviewViewedProgress(files: snapshot.files))

        store.selectComparison(before: baseline, after: firstSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection.mode == .commit)
        #expect(store.viewedProgress.total == 1)
        #expect(store.viewedProgress.viewed == 0)
        #expect(store.viewedProgress.unviewed == 1)
        let path = try #require(store.comparisonFiles.first?.path)

        await store.setViewed(paths: [path], viewed: true)
        #expect(store.viewedProgress.viewed == 1)
        #expect(store.viewedProgress.unviewed == 0)
        #expect(store.viewedProgress.isComplete)
        #expect(store.snapshot?.files.first(where: { $0.path == path })?.viewed == false)

        store.selectComparison(before: firstSHA, after: snapshot.review.headSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection.mode == .range)
        #expect(store.viewedProgress.total == 1)
        #expect(store.viewedProgress.viewed == 0)
        #expect(store.viewedProgress.unviewed == 1)

        store.selectComparison(before: baseline, after: snapshot.review.headSHA)
        await store.loadComparison()
        #expect(store.comparisonSelection == .all)
        #expect(store.viewedProgress == wholePR)

        store.selectComparison(before: baseline, after: firstSHA)
        await store.loadComparison()
        #expect(store.viewedProgress.isComplete, "Returning to a comparison retains its local Viewed marks")
        await store.setViewed(paths: [path], viewed: false)
        #expect(store.viewedProgress.unviewed == 1)
    }

    @Test("Badge, row accessibility, and completion actions share exact copy")
    func presentationCopy() {
        #expect(PRReviewViewedProgress.viewedBadgeLabel == "Viewed")
        #expect(PRReviewViewedProgress.rowAccessibilityValue(viewed: true) == "Viewed")
        #expect(PRReviewViewedProgress.rowAccessibilityValue(viewed: false) == "Not viewed")
        #expect(PRReviewViewedProgress.allViewedTitle == "All files viewed")
        #expect(PRReviewViewedProgress.allViewedDetail == "Turn off Hide viewed to see them again.")
        #expect(PRReviewViewedProgress.showViewedLabel == "Show viewed files")
    }
}
