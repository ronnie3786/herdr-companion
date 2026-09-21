import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review window", .serialized)
struct PRReviewWindowTests {
    @Test("Target identity is exactly the machine and review")
    func targetIdentityIsMachineAndReview() throws {
        let target = PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_alpha")

        #expect(target == PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_alpha"))
        #expect(target != PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_beta"))
        #expect(target != PRReviewWindowTarget(machineID: "machine-b", reviewID: "prr_alpha"))
        #expect(target.id == "machine-a|prr_alpha")
        #expect(Set([target, PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_alpha")]).count == 1)
        #expect(target.windowAccessibilityIdentifier == "pr-review-window-machine-a|prr_alpha")
        #expect(target.popOutActionAccessibilityIdentifier == "pr-review-pop-out-machine-a|prr_alpha")

        let decoded = try JSONDecoder().decode(PRReviewWindowTarget.self, from: JSONEncoder().encode(target))
        #expect(decoded == target)
        #expect(decoded.windowAccessibilityIdentifier == target.windowAccessibilityIdentifier)
    }

    @Test("Duplicate labels and numbers are presentation, not identity")
    func duplicateLabelsAndNumbersStayDistinct() {
        var review = PRReviewDemo.snapshot().review
        review.number = 7
        review.title = "Identical synthetic title"

        let first = PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_alpha")
        var second = review
        second.id = "prr_beta"
        let secondTarget = PRReviewWindowTarget(machineID: "machine-a", reviewID: second.id)

        #expect(first != secondTarget)
        #expect(first.windowAccessibilityIdentifier != secondTarget.windowAccessibilityIdentifier)
        #expect(first.popOutActionAccessibilityIdentifier != secondTarget.popOutActionAccessibilityIdentifier)
    }

    @Test("The same review id on two hosts is two windows")
    func identicalReviewIDsOnDifferentHostsStayDistinct() {
        let first = PRReviewWindowTarget(machineID: "machine-a", reviewID: "prr_shared")
        let second = PRReviewWindowTarget(machineID: "machine-b", reviewID: "prr_shared")

        #expect(first != second)
        #expect(first.id != second.id)
        #expect(Set([first, second]).count == 2)
        #expect(first.windowAccessibilityIdentifier != second.windowAccessibilityIdentifier)
    }

    @Test("Host resolution separates demo, available, removed, and unconfigured hosts")
    func hostResolutionBranches() {
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: true, targetMachineExists: false, hasConfiguration: false
        ) == .demo)
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: false, targetMachineExists: true, hasConfiguration: true
        ) == .available)
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: false, targetMachineExists: true, hasConfiguration: false
        ) == .unconfigured)
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: false, targetMachineExists: false, hasConfiguration: true
        ) == .missingHost)
        #expect(PRReviewWindowHostResolver.resolve(
            isDemoTarget: false, targetMachineExists: false, hasConfiguration: false
        ) == .missingHost)
        #expect(PRReviewWindowHostState.missingHost.isUsable == false)
        #expect(PRReviewWindowHostState.unconfigured.isUsable == false)
        #expect(PRReviewWindowHostState.available.isUsable)
        #expect(PRReviewWindowHostState.demo.isUsable)
    }

    @Test("Seed capture copies presentation only for the exact machine and review")
    func seedCaptureRequiresExactTarget() {
        let main = PRReviewStore()
        main.configure(client: nil, machineID: "machine-a", demo: true)
        main.tab = .context
        main.selectedPath = "Sources/Catalog/SyncClient.swift"
        main.viewMode = .guided
        main.impactFilter = .high
        main.hideViewed = true
        main.search = "Sync"
        main.showArchived = true

        let matching = PRReviewWindowSeed.capture(
            from: main,
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        #expect(matching?.tab == .context)
        #expect(matching?.selectedPath == "Sources/Catalog/SyncClient.swift")
        #expect(matching?.viewMode == .guided)
        #expect(matching?.impactFilter == .high)
        #expect(matching?.hideViewed == true)
        #expect(matching?.search == "Sync")
        #expect(matching?.showArchived == true)
        #expect(PRReviewWindowSeed.capture(
            from: main,
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.secondReviewID)
        ) == nil)
        #expect(PRReviewWindowSeed.capture(
            from: main,
            target: PRReviewWindowTarget(machineID: "machine-b", reviewID: PRReviewDemo.reviewID)
        ) == nil)
    }

    @Test("Activation applies a matching seed and preserves the selected file across refresh")
    func activationSeedsAndPreservesFile() async {
        let target = PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        let session = PRReviewWindowSession(target: target)
        let client = SyntheticPRReviewWindowClient()
        let seed = PRReviewWindowSeed(
            tab: .context,
            selectedPath: "Sources/Catalog/SyncClient.swift",
            viewMode: .guided,
            impactFilter: .all,
            hideViewed: false,
            search: "",
            showArchived: false
        )

        await session.activate(
            identity: "machine-a",
            hostState: .available,
            client: client,
            seed: seed
        )

        #expect(session.store.currentMachineID == "machine-a")
        #expect(session.store.selectedReviewID == PRReviewDemo.reviewID)
        #expect(session.store.tab == .context)
        #expect(session.store.viewMode == .guided)
        #expect(session.store.selectedPath == "Sources/Catalog/SyncClient.swift")
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)

        await session.refreshFromEventTick()
        #expect(session.store.selectedPath == "Sources/Catalog/SyncClient.swift")

        await session.store.refreshSelected()
        #expect(session.store.selectedPath == "Sources/Catalog/SyncClient.swift")

        await session.store.loadDiff(for: session.store.selectedPath)
        #expect(await client.diffPaths == ["Sources/Catalog/SyncClient.swift"])
        #expect(session.store.diff?.reviewID == PRReviewDemo.reviewID)
    }

    @Test("A window without a matching seed keeps its own defaults")
    func activationWithoutSeedKeepsDefaults() async {
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        await session.activate(
            identity: "machine-a",
            hostState: .available,
            client: SyntheticPRReviewWindowClient(),
            seed: nil
        )

        #expect(session.store.tab == .files)
        #expect(session.store.viewMode == .github)
        #expect(session.store.impactFilter == .all)
        #expect(session.store.selectedPath == nil)
    }

    @Test("A demo pop-out targets the exact review and loads its own diff")
    func demoWindowTargetsExactReview() async {
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "demo", reviewID: PRReviewDemo.secondReviewID)
        )

        await session.activate(identity: "demo", hostState: .demo, client: nil, seed: nil)

        #expect(session.canControl)
        #expect(session.store.currentMachineID == "demo")
        #expect(session.store.selectedReviewID == PRReviewDemo.secondReviewID)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.secondReviewID)

        let path = session.store.orderedFiles.first?.path
        session.store.selectedPath = path
        await session.store.loadDiff(for: path)
        #expect(session.store.diff?.reviewID == PRReviewDemo.secondReviewID)
        #expect(session.store.diff?.files.first?.path == path)
    }

    @Test("An unavailable host never configures or polls a fallback store")
    func unavailableHostDoesNotConfigureStore() async {
        let client = SyntheticPRReviewWindowClient()
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "removed-host", reviewID: "prr_orphan")
        )

        await session.activate(
            identity: "removed-host",
            hostState: .missingHost,
            client: client,
            seed: nil
        )

        #expect(session.hostState == .missingHost)
        #expect(!session.canControl)
        #expect(session.store.currentMachineID == nil)
        #expect(session.store.reviews.isEmpty)
        #expect(!session.isPolling)
        #expect(await client.capabilitiesCallCount == 0)
    }

    @Test("Re-activating the same identity is a no-op")
    func repeatedActivationIsIdempotent() async {
        let client = SyntheticPRReviewWindowClient()
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        await session.activate(identity: "same", hostState: .available, client: client, seed: nil)
        await session.activate(identity: "same", hostState: .available, client: client, seed: nil)

        #expect(await client.capabilitiesCallCount == 1)
        #expect(session.isPolling)
    }

    @Test("A late activation cannot replace the newer host")
    func lateActivationIsDropped() async {
        let gate = SyntheticPRReviewGate()
        let late = SyntheticPRReviewWindowClient(capabilitiesGate: gate)
        let current = SyntheticPRReviewWindowClient()
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        let first = Task {
            await session.activate(identity: "late", hostState: .available, client: late, seed: nil)
        }
        await gate.waitUntilWaiting()
        await session.activate(identity: "current", hostState: .available, client: current, seed: nil)
        await gate.release()
        await first.value

        #expect(session.store.currentMachineID == "machine-a")
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(await late.reviewIDs.isEmpty)
        #expect(await current.reviewIDs == [PRReviewDemo.reviewID])
    }

    @Test("Stopping a session invalidates an in-flight activation")
    func stopInvalidatesInFlightActivation() async {
        let gate = SyntheticPRReviewGate()
        let client = SyntheticPRReviewWindowClient(capabilitiesGate: gate)
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        let activation = Task {
            await session.activate(identity: "machine-a", hostState: .available, client: client, seed: nil)
        }
        await gate.waitUntilWaiting()
        session.stop()
        await gate.release()
        await activation.value

        #expect(!session.isPolling)
        #expect(await client.capabilitiesCallCount == 1)
    }

    @Test("A seeded file survives a mounted files view while its snapshot is loading")
    func seedSurvivesAsynchronousLoading() async throws {
        let gate = SyntheticPRReviewGate()
        let client = SyntheticPRReviewWindowClient(reviewGate: gate)
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )
        let seededPath = "Sources/Models/Seed.swift"
        let seed = PRReviewWindowSeed(
            tab: .files,
            selectedPath: seededPath,
            viewMode: .github,
            impactFilter: .all,
            hideViewed: false,
            search: "",
            showArchived: false
        )

        let activation = Task {
            await session.activate(identity: "machine-a", hostState: .available, client: client, seed: seed)
        }
        await gate.waitUntilWaiting()

        // The summaries are already published while the selected snapshot is
        // still in flight, so the mounted files view sees an empty list first.
        #expect(session.store.snapshot == nil)
        #expect(session.store.selectedReview != nil)
        let window = try await mountFilesView(session.store)
        defer { window.close() }
        try await pump(window)

        await gate.release()
        await activation.value
        try await pump(window)

        #expect(session.store.selectedPath == seededPath)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
    }

    @Test("A re-activation swaps clients without replaying the seed or losing the chosen file")
    func reconnectionPreservesPresentationAndConsumesSeed() async {
        let first = SyntheticPRReviewWindowClient()
        let second = SyntheticPRReviewWindowClient()
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )
        let seed = PRReviewWindowSeed(
            tab: .context,
            selectedPath: "Sources/Models/Seed.swift",
            viewMode: .guided,
            impactFilter: .high,
            hideViewed: true,
            search: "Seed",
            showArchived: true
        )

        await session.activate(identity: "first", hostState: .available, client: first, seed: seed)
        #expect(session.store.selectedPath == "Sources/Models/Seed.swift")

        // User-owned state after the first activation must survive a
        // credential/URL change rather than resetting to the original seed.
        session.store.selectedPath = "Sources/Storage/SeedStore.swift"
        session.store.tab = .agents

        await session.activate(identity: "second", hostState: .available, client: second, seed: seed)

        #expect(session.store.selectedPath == "Sources/Storage/SeedStore.swift")
        #expect(session.store.tab == .agents)
        #expect(session.store.viewMode == .guided)
        #expect(session.store.impactFilter == .high)
        #expect(session.store.search == "Seed")
        #expect(session.store.showArchived == true)
        #expect(session.store.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(await first.reviewIDs == [PRReviewDemo.reviewID])
        #expect(await second.reviewIDs == [PRReviewDemo.reviewID])

        await session.store.loadDiff(for: "Sources/Storage/SeedStore.swift")
        #expect(await second.diffPaths == ["Sources/Storage/SeedStore.swift"])
        #expect(await first.diffPaths.isEmpty)
    }

    @Test("Stopping a session rejects its late snapshot and drops document transport")
    func stopRejectsLateSnapshotAndTransport() async throws {
        let gate = SyntheticPRReviewGate()
        let client = SyntheticPRReviewWindowClient(reviewGate: gate)
        let cache = PRReviewDocumentCache(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "PRReviewWindowTests-\(UUID().uuidString)")
        )
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID),
            store: PRReviewStore(documentCache: cache)
        )

        let activation = Task {
            await session.activate(identity: "machine-a", hostState: .available, client: client, seed: nil)
        }
        await gate.waitUntilWaiting()
        session.stop()
        await gate.release()
        await activation.value

        // The snapshot arrived after the stop and must not be installed.
        #expect(session.store.snapshot == nil)
        #expect(await client.reviewIDs == [PRReviewDemo.reviewID])

        session.store.selectedPath = "Sources/Models/Seed.swift"
        await session.store.loadDiff(for: session.store.selectedPath)
        #expect(await client.diffPaths.isEmpty)

        var document = PRReviewDemo.snapshot().documents[0]
        document.id = "prdoc_after_stop"
        document.contentHash = "after-stop"
        await #expect(throws: (any Error).self) {
            try await session.store.localURL(for: document)
        }
        #expect(await client.downloadRequests.isEmpty)
    }

    @Test("A host that becomes unavailable drops the old transport and refuses late snapshots")
    func unavailableTransitionInvalidatesStore() async {
        let gate = SyntheticPRReviewGate()
        let client = SyntheticPRReviewWindowClient(reviewGate: gate)
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )

        let activation = Task {
            await session.activate(identity: "available", hostState: .available, client: client, seed: nil)
        }
        await gate.waitUntilWaiting()

        await session.activate(identity: "removed", hostState: .missingHost, client: nil, seed: nil)
        #expect(session.hostState == .missingHost)
        #expect(!session.canControl)

        await gate.release()
        await activation.value

        #expect(session.store.snapshot == nil)
        session.store.selectedPath = "Sources/Models/Seed.swift"
        await session.store.loadDiff(for: session.store.selectedPath)
        #expect(await client.diffPaths.isEmpty)
    }

    @Test("Polling starts with activation and stops on close")
    func pollingLifecycle() async {
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID),
            pollingInterval: { _ in .seconds(30) }
        )

        await session.activate(
            identity: "machine-a",
            hostState: .available,
            client: SyntheticPRReviewWindowClient(),
            seed: nil
        )
        #expect(session.isPolling)

        session.stop()
        #expect(!session.isPolling)
    }

    @Test("Transient presentation flags stay on their own window session")
    func transientFlagsAreSessionLocal() {
        let first = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID)
        )
        let second = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.secondReviewID)
        )

        first.setQuestionDraft(true)
        first.setCreating(true)
        first.setAddingSkill(true)

        #expect(first.hasQuestionDraft)
        #expect(first.isCreating)
        #expect(first.isAddingSkill)
        #expect(!second.hasQuestionDraft)
        #expect(!second.isCreating)
        #expect(!second.isAddingSkill)
    }

    @Test("Document window reuse is scoped by machine, review, document, and kind")
    func documentWindowReuseIsFullyScoped() {
        let document = PRReviewDemo.snapshot().documents[0]
        let firstHost = PRReviewStore()
        firstHost.configure(client: nil, machineID: "machine-a", demo: false)
        let secondHost = PRReviewStore()
        secondHost.configure(client: nil, machineID: "machine-b", demo: false)

        let markdown = PRReviewDocumentWindow.reuseKey(kind: "markdown", document: document, store: firstHost)
        let html = PRReviewDocumentWindow.reuseKey(kind: "html", document: document, store: firstHost)
        let otherHost = PRReviewDocumentWindow.reuseKey(kind: "markdown", document: document, store: secondHost)
        var otherReview = document
        otherReview.reviewID = "prr_other_review"
        let otherReviewKey = PRReviewDocumentWindow.reuseKey(kind: "markdown", document: otherReview, store: firstHost)
        var otherDocument = document
        otherDocument.id = "prdoc_other"
        let otherDocumentKey = PRReviewDocumentWindow.reuseKey(kind: "markdown", document: otherDocument, store: firstHost)

        #expect(markdown != html)
        #expect(markdown != otherHost)
        #expect(markdown != otherReviewKey)
        #expect(markdown != otherDocumentKey)
        #expect(markdown == PRReviewDocumentWindow.reuseKey(kind: "markdown", document: document, store: firstHost))
    }

    @Test("A document window session owns an independent store pinned to the opening host")
    func documentWindowSessionPinsHost() async throws {
        let firstHost = SyntheticPRReviewWindowClient()
        let secondHost = SyntheticPRReviewWindowClient()
        let store = PRReviewStore(documentCache: temporaryDocumentCache())
        store.configure(client: firstHost, machineID: "machine-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        let document = PRReviewDemo.snapshot().documents[0]

        let session = try #require(PRReviewDocumentWindow.makeSession(kind: "markdown", document: document, store: store))
        #expect(session.store !== store)
        #expect(session.store.currentMachineID == "machine-a")
        #expect(session.store.selectedReviewID == document.reviewID)
        #expect(session.reuseKey == PRReviewDocumentWindow.reuseKey(kind: "markdown", document: document, store: store))

        // The first download fails; then the main store switches to another
        // configured host. The retained window still downloads host A's
        // document in a retry instead of host B's copies of the same ids.
        await #expect(throws: (any Error).self) {
            try await session.store.localURL(for: document)
        }
        store.configure(client: secondHost, machineID: "machine-b", demo: false)
        await #expect(throws: (any Error).self) {
            try await session.store.localURL(for: document)
        }

        #expect(await firstHost.downloadRequests == [document.id, document.id])
        #expect(await secondHost.downloadRequests.isEmpty)
        #expect(session.store.currentMachineID == "machine-a")
    }

    @Test("A retained document window retries after its originating review closes")
    func documentWindowRetriesAfterOriginatingReviewCloses() async throws {
        let attempts = SyntheticDownloadAttempts()
        let client = SyntheticPRReviewWindowClient(downloadHandler: { _, _, destination in
            if await attempts.next() == 1 {
                throw APIError.invalidResponse
            }
            try Data("synthetic review report".utf8).write(to: destination, options: .atomic)
        })
        let cache = temporaryDocumentCache()
        let session = PRReviewWindowSession(
            target: PRReviewWindowTarget(machineID: "machine-a", reviewID: PRReviewDemo.reviewID),
            store: PRReviewStore(documentCache: cache)
        )
        await session.activate(identity: "machine-a", hostState: .available, client: client, seed: nil)
        let document = PRReviewDemo.snapshot().documents[0]
        let windowSession = try #require(PRReviewDocumentWindow.makeSession(kind: "html", document: document, store: session.store))

        await #expect(throws: (any Error).self) {
            try await windowSession.store.localURL(for: document)
        }

        // Closing the pop-out invalidates its presentation store, but the
        // retained document window keeps its own pinned transport and can
        // still retry the download.
        session.stop()
        #expect(session.store.documentTransport(for: document) == nil)

        let url = try await windowSession.store.localURL(for: document)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "synthetic review report")
        #expect(await client.downloadRequests == [document.id, document.id])
    }

    @Test("An unconfigured or invalidated store cannot open a document window")
    func documentWindowRequiresPinnedHost() {
        let document = PRReviewDemo.snapshot().documents[0]
        let store = PRReviewStore(documentCache: temporaryDocumentCache())
        #expect(PRReviewDocumentWindow.makeSession(kind: "html", document: document, store: store) == nil)

        store.configure(client: SyntheticPRReviewWindowClient(), machineID: "machine-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        #expect(PRReviewDocumentWindow.makeSession(kind: "html", document: document, store: store) != nil)

        store.invalidateConnection()
        #expect(PRReviewDocumentWindow.makeSession(kind: "html", document: document, store: store) == nil)
    }

    @Test("A document window reconnects on credential rotation and refuses a removed host")
    func documentWindowObservesRotatedAndRemovedHosts() async throws {
        let first = SyntheticPRReviewWindowClient(downloadHandler: { _, _, _ in
            throw APIError.invalidResponse
        })
        let second = SyntheticPRReviewWindowClient(downloadHandler: { _, _, destination in
            try Data("synthetic report".utf8).write(to: destination, options: .atomic)
        })
        let resources = PRReviewDocumentResources(cache: temporaryDocumentCache())
        let store = PRReviewStore(documentResources: resources)
        store.configure(client: first, machineID: "machine-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        let document = PRReviewDemo.snapshot().documents[0]
        let session = PRReviewDocumentWindowSession(document: document, store: store)

        await session.activate(identity: "before-rotation", hostState: .available, client: first)
        await #expect(throws: (any Error).self) {
            try await store.localURL(for: document)
        }

        // A token or URL edit for the pinned machine swaps the transport, so
        // Try Again reaches the rotated credential rather than the old client.
        await session.activate(identity: "after-rotation", hostState: .available, client: second)
        let url = try await store.localURL(for: document)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "synthetic report")
        #expect(await first.downloadRequests == [document.id])
        #expect(await second.downloadRequests == [document.id])

        // Removing the machine invalidates the authenticated transport; the
        // window owns that decision independent of the originating review.
        await session.activate(identity: "after-removal", hostState: .missingHost, client: nil)
        #expect(session.hostState == .missingHost)
        #expect(store.documentTransport(for: document) == nil)
        #expect(store.currentMachineID == "machine-a")
        #expect(session.machineID == "machine-a")

        let third = SyntheticPRReviewWindowClient()
        await session.activate(identity: "after-readd", hostState: .available, client: third)
        #expect(session.hostState == .available)
        #expect(store.documentTransport(for: document) != nil)
        #expect(store.currentMachineID == "machine-a")
        #expect(session.revision == 4)
    }

    @Test("Closing a document window releases its cache leases")
    func documentWindowStopReleasesLeases() async throws {
        let resources = PRReviewDocumentResources(cache: temporaryDocumentCache())
        let client = SyntheticPRReviewWindowClient(downloadHandler: { _, _, destination in
            try Data("synthetic report".utf8).write(to: destination, options: .atomic)
        })
        let store = PRReviewStore(documentResources: resources)
        store.configure(client: client, machineID: "machine-a", demo: false)
        store.select(PRReviewDemo.reviewID)
        let document = PRReviewDemo.snapshot().documents[0]
        let session = PRReviewDocumentWindowSession(document: document, store: store)
        await session.activate(identity: "window", hostState: .available, client: client)

        let url = try await store.localURL(for: document)
        _ = store.acquireDocumentLease(for: url)
        #expect(resources.protectedURLs.contains(url.standardizedFileURL))

        session.stop()
        #expect(!resources.protectedURLs.contains(url.standardizedFileURL))
        #expect(store.documentTransport(for: document) == nil)
    }

    @Test("Markdown and HTML document windows publish Ready to the originating rail")
    func documentWindowsPublishReadyPhaseToOriginatingStore() async throws {
        for kind in ["markdown", "html"] {
            let resources = PRReviewDocumentResources(cache: temporaryDocumentCache())
            let client = SyntheticPRReviewWindowClient(downloadHandler: { _, _, destination in
                try Data("synthetic \(kind) report".utf8).write(to: destination, options: .atomic)
            })
            let document = kind == "html"
                ? PRReviewDemo.snapshot().documents[1]
                : PRReviewDemo.snapshot().documents[0]
            let main = PRReviewStore(documentResources: resources)
            main.configure(client: client, machineID: "machine-a", demo: false)
            main.select(document.reviewID)

            // The production document-window session owns the download while
            // the Context rail that offered Open keeps reading the shared
            // machine/review/document-scoped phase.
            let session = try #require(
                PRReviewDocumentWindow.makeSession(kind: kind, document: document, store: main)
            )
            let url = try await session.store.localURL(for: document)

            #expect(main.documentPhases[document.id] == .ready(url))
            #expect(session.store.documentPhases[document.id] == .ready(url))
        }
    }

    @Test("A retention cleanup cannot evict a document another window is displaying")
    func retentionCleanupProtectsDisplayedDocumentsAcrossStores() async throws {
        let resources = PRReviewDocumentResources(cache: PRReviewDocumentCache(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "PRReviewWindowTests-\(UUID().uuidString)"),
            retentionPolicy: .init(
                maximumFileCount: 1,
                maximumByteCount: .max,
                maximumAge: 60 * 60 * 24 * 365
            )
        ))
        let client = SyntheticPRReviewWindowClient(downloadHandler: { _, documentID, destination in
            try Data("synthetic \(documentID)".utf8).write(to: destination, options: .atomic)
        })
        let firstDocument = syntheticDocument(id: "prdoc_window_first", filename: "first.md")
        let secondDocument = syntheticDocument(id: "prdoc_window_second", filename: "second.md")

        let firstStore = PRReviewStore(documentResources: resources)
        firstStore.configure(client: client, machineID: "machine-a", demo: false)
        firstStore.select(firstDocument.reviewID)
        let secondStore = PRReviewStore(documentResources: resources)
        secondStore.configure(client: client, machineID: "machine-a", demo: false)
        secondStore.select(secondDocument.reviewID)

        let firstURL = try await firstStore.localURL(for: firstDocument)
        _ = firstStore.acquireDocumentLease(for: firstURL)
        #expect(resources.protectedURLs.contains(firstURL.standardizedFileURL))

        // The second window's download runs cleanup at the one-file retention
        // limit. The first window's lease keeps its displayed file alive, and
        // the just-installed second destination is protected as well.
        let secondURL = try await secondStore.localURL(for: secondDocument)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))

        // Closing the first window releases its lease; only then does cleanup
        // evict the now-unprotected oldest file and forget its Ready phase.
        firstStore.releaseOutstandingDocumentLeases()
        #expect(!resources.protectedURLs.contains(firstURL.standardizedFileURL))
        try resources.cleanup()
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(firstStore.documentPhases[firstDocument.id] == nil)
    }

    private func syntheticDocument(id: String, filename: String) -> PRReviewDocument {
        PRReviewDocument(
            id: id,
            reviewID: PRReviewDemo.reviewID,
            runID: nil,
            kind: .markdown,
            title: filename,
            mediaType: "text/markdown",
            filename: filename,
            url: nil,
            byteSize: 16,
            contentHash: id,
            origin: "skill",
            originPath: nil,
            createdAt: nil,
            downloadable: true
        )
    }

    private func temporaryDocumentCache() -> PRReviewDocumentCache {
        PRReviewDocumentCache(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "PRReviewWindowTests-\(UUID().uuidString)")
        )
    }

    // MARK: Mounted files view helpers

    private func mountFilesView(_ store: PRReviewStore) async throws -> NSWindow {
        let size = CGSize(width: 980, height: 620)
        let hosting = NSHostingView(rootView:
            PRReviewFilesView(store: store)
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
        return window
    }

    private func pump(_ window: NSWindow) async throws {
        guard let hosting = window.contentView else { return }
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// A request gate for deterministic cancellation and late-response tests.
actor SyntheticPRReviewGate {
    private var isWaiting = false
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isWaiting = true
        let arrivals = arrivalContinuations
        arrivalContinuations.removeAll()
        arrivals.forEach { $0.resume() }
        await withCheckedContinuation { responseContinuation = $0 }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { arrivalContinuations.append($0) }
    }

    func release() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}

/// Counts document download attempts so a retry can be distinguished from
/// the first failed download without inspecting private cache state.
actor SyntheticDownloadAttempts {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// A synthetic PR Review client with demo-backed responses and observable call
/// counts. Counts are read from tests with `await`.
actor SyntheticPRReviewWindowClient: PRReviewClient {
    private(set) var capabilitiesCallCount = 0
    private(set) var reviewIDs: [String] = []
    private(set) var diffPaths: [String] = []
    private let capabilitiesGate: SyntheticPRReviewGate?
    private let reviewGate: SyntheticPRReviewGate?
    private let capabilitiesError: APIError?
    private let reviewError: APIError?
    private let downloadHandler: (@Sendable (String, String, URL) async throws -> Void)?
    private(set) var downloadRequests: [String] = []

    init(
        capabilitiesGate: SyntheticPRReviewGate? = nil,
        reviewGate: SyntheticPRReviewGate? = nil,
        capabilitiesError: APIError? = nil,
        reviewError: APIError? = nil,
        downloadHandler: (@Sendable (String, String, URL) async throws -> Void)? = nil
    ) {
        self.capabilitiesGate = capabilitiesGate
        self.reviewGate = reviewGate
        self.capabilitiesError = capabilitiesError
        self.reviewError = reviewError
        self.downloadHandler = downloadHandler
    }

    func prReviewCapabilities() async throws -> PRReviewCapabilities {
        capabilitiesCallCount += 1
        if let capabilitiesGate { await capabilitiesGate.wait() }
        if let capabilitiesError { throw capabilitiesError }
        return try decode("{\"ok\":true,\"capabilities\":[\"pr-review-v1\"],\"available\":true,\"skills\":[]}")
    }

    func prReviewSkills() async throws -> [PRReviewSkill] { [] }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill {
        PRReviewDemo.snapshot().skills[0].skill
    }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { [] }
    func prReviews(scope: String) async throws -> [PRReviewSummary] {
        scope == "archived" ? PRReviewDemo.archivedReviews() : PRReviewDemo.reviews()
    }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot {
        PRReviewDemo.snapshot()
    }
    func prReview(id: String) async throws -> PRReviewSnapshot {
        reviewIDs.append(id)
        if let reviewGate { await reviewGate.wait() }
        if let reviewError { throw reviewError }
        return PRReviewDemo.snapshot(for: id)
    }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot {
        PRReviewDemo.snapshot(for: id)
    }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot {
        PRReviewDemo.snapshot(for: id)
    }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff {
        diffPaths.append(path ?? "")
        return PRReviewDemo.diff(for: id)
    }
    func prReviewFileText(
        id: String,
        path: String,
        side: PRReviewSide,
        start: Int?,
        end: Int?
    ) async throws -> PRReviewFileText { throw APIError.invalidResponse }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { throw APIError.invalidResponse }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun {
        throw APIError.invalidResponse
    }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func finishPRReviewRun(
        reviewID: String,
        runID: String,
        state: PRReviewRunState,
        note: String?,
        requestID: String
    ) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { "" }
    func markPRReviewSkill(
        reviewID: String,
        skillID: String,
        state: String,
        note: String?,
        requestID: String
    ) async throws -> PRReviewSkillState { PRReviewDemo.snapshot().skills[0] }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary {
        PRReviewDemo.snapshot(for: id).review
    }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { [] }
    func setPRReviewViewed(
        id: String,
        paths: [String],
        viewed: Bool,
        requestID: String
    ) async throws -> [PRReviewFile] { PRReviewDemo.snapshot(for: id).files }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { [] }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { [] }
    func addPRReviewDocument(
        id: String,
        payload: PRReviewDocumentPayload,
        requestID: String
    ) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument {
        throw APIError.invalidResponse
    }
    func downloadPRReviewDocument(
        reviewID: String,
        documentID: String,
        expectedByteSize: Int64,
        to destinationURL: URL
    ) async throws {
        downloadRequests.append(documentID)
        if let downloadHandler {
            try await downloadHandler(reviewID, documentID, destinationURL)
            return
        }
        throw APIError.invalidResponse
    }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { [] }

    private func decode<T: Decodable>(_ string: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(string.utf8))
    }
}
