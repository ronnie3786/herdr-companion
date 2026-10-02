import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review fleet index", .timeLimit(.minutes(1)))
struct PRReviewFleetIndexTests {
    @Test("Missing or removed host selections resolve to All machines")
    func scopeResolution() {
        let hosts = ["host-a", "host-b"]
        #expect(PRReviewHostScope.allMachinesTitle == "All machines")
        #expect(PRReviewHostScope.resolved(nil, availableMachineIDs: hosts) == .all)
        #expect(PRReviewHostScope.resolved(.all, availableMachineIDs: hosts) == .all)
        #expect(PRReviewHostScope.resolved(.machine("host-b"), availableMachineIDs: hosts) == .machine("host-b"))
        #expect(PRReviewHostScope.resolved(.machine("removed"), availableMachineIDs: hosts) == .all)
        #expect(PRReviewHostScope.resolved(nil, availableMachineIDs: []) == .all)
        #expect(PRReviewHostScope.resolved(.all, availableMachineIDs: []) == .all)
        #expect(PRReviewHostScope.resolved(.machine("host-a"), availableMachineIDs: []) == .all)
    }

    @Test("Roster identity includes every connection and presentation input")
    func identityIncludesAllInputs() {
        func identity(
            id: String = "host-a", name: String = "Alpha", url: String = "https://host-a.example.invalid",
            token: String = "synthetic-a", generation: Int = 1, isDemo: Bool = false
        ) -> PRReviewFleetIdentity {
            .init(isDemo: isDemo, generation: generation, machines: [
                .init(id: id, name: name, urlString: url, token: token),
            ])
        }
        let initial = identity()
        #expect(initial == identity())
        let variants = [
            initial,
            identity(id: "host-b"),
            identity(name: "Renamed"),
            identity(url: "https://host-b.example.invalid"),
            identity(token: "synthetic-rotated"),
            identity(generation: 2),
            identity(isDemo: true),
            PRReviewFleetIdentity(isDemo: false, generation: 1, machines: []),
        ]
        #expect(Set(variants).count == variants.count)
        let machineA = initial.machines[0]
        let machineB = identity(id: "host-b").machines[0]
        #expect(PRReviewFleetIdentity(isDemo: false, generation: 1, machines: [machineA, machineB])
            != PRReviewFleetIdentity(isDemo: false, generation: 1, machines: [machineB, machineA]))
    }

    @Test("Every host contributes active and archived reviews in roster then server order")
    func combinesBothScopes() async {
        let a1 = review("prr_a2", title: "Second by ID, first on server")
        let a2 = review("prr_a1", title: "First by ID, second on server")
        let aArchived = review("prr_a_archive", archived: true)
        let b1 = review("prr_b1")
        let bArchived = review("prr_b_archive", archived: true)
        let alpha = SyntheticPRReviewFleetClient(active: [a1, a2], archived: [aArchived])
        let beta = SyntheticPRReviewFleetClient(active: [b1], archived: [bArchived])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: "initial")

        #expect(index.sourceCount == 2)
        #expect(!index.hasLoaded && !index.isRefreshing)
        await index.refresh()

        #expect(index.active == [
            .init(machineID: "host-a", machineName: "Alpha", review: a1),
            .init(machineID: "host-a", machineName: "Alpha", review: a2),
            .init(machineID: "host-b", machineName: "Beta", review: b1),
        ])
        #expect(index.archived == [
            .init(machineID: "host-a", machineName: "Alpha", review: aArchived),
            .init(machineID: "host-b", machineName: "Beta", review: bArchived),
        ])
        #expect(index.hasLoaded && !index.isRefreshing)
        #expect(index.notices.isEmpty)
        #expect(await alpha.listScopes.sorted() == ["active", "archived"])
        #expect(await beta.listScopes.sorted() == ["active", "archived"])
    }

    @Test("Both lists on all machines are fetched concurrently")
    func requestsAreConcurrent() async throws {
        let aActive = PRReviewFleetGate()
        let aArchived = PRReviewFleetGate()
        let bActive = PRReviewFleetGate()
        let bArchived = PRReviewFleetGate()
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")], listGates: ["active": aActive, "archived": aArchived])
        let beta = SyntheticPRReviewFleetClient(active: [review("prr_b")], listGates: ["active": bActive, "archived": bArchived])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        let refresh = Task { await index.refresh() }
        defer { refresh.cancel() }
        for gate in [aActive, aArchived, bActive, bArchived] { try await gate.waitForRequest() }
        #expect(index.isRefreshing)
        #expect(!index.hasLoaded)
        // A healthy machine publishes while the other host is still waiting.
        await bActive.release()
        await bArchived.release()
        try await waitUntil { index.active.count == 1 }
        #expect(index.active.first?.machineID == "host-b")
        await aActive.release()
        await aArchived.release()
        await refresh.value
        #expect(index.active.map(\.machineID) == ["host-a", "host-b"])
        #expect(!index.isRefreshing)
    }

    @Test("Duplicate review IDs, titles and PR numbers remain distinct across machines")
    func duplicateIDsAreMachineQualified() async {
        let shared = review("prr_shared", title: "Same synthetic title")
        let alpha = SyntheticPRReviewFleetClient(active: [shared])
        let beta = SyntheticPRReviewFleetClient(active: [shared])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Same name", alpha), source("host-b", "Same name", beta)], identity: 1)
        await index.refresh()

        #expect(index.active.count == 2)
        #expect(Set(index.active.map(\.id)).count == 2)
        #expect(index.active.map(\.id) == [target("host-a", "prr_shared"), target("host-b", "prr_shared")])
        #expect(index.entry(for: target("host-b", "prr_shared"))?.machineID == "host-b")
        #expect(index.contains(target("host-a", "prr_shared")))
        #expect(!index.contains(target("host-c", "prr_shared")))
        #expect(index.entry(for: target("host-a", "missing")) == nil)
    }

    @Test("Unsupported and unreachable hosts leave other hosts visible", arguments: [404, 501, 0])
    func partialFailure(status: Int) async {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")], archived: [review("prr_a_old", archived: true)])
        let beta = SyntheticPRReviewFleetClient()
        await beta.setListError(status == 0 ? SyntheticPRReviewFleetError.offline : APIError.server(status: status, message: "Missing route"))
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        await index.refresh()

        #expect(index.active.map(\.machineID) == ["host-a"])
        #expect(index.archived.map(\.machineID) == ["host-a"])
        #expect(index.notices == [.init(machineID: "host-b", machineName: "Beta", message: status == 0
            ? SyntheticPRReviewFleetError.offline.localizedDescription
            : "Update this machine's companion for PR Review (pr-review-v1).")])
        #expect(index.hasLoaded && !index.isRefreshing)
    }

    @Test("A failed host keeps both last good lists and clears its notice on recovery")
    func lastGoodListsSurviveAndRecoveryClearsNotice() async {
        let original = review("prr_b")
        let archived = review("prr_b_old", archived: true)
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")])
        let beta = SyntheticPRReviewFleetClient(active: [original], archived: [archived])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        await index.refresh()
        await alpha.setLists(active: [review("prr_a_new")], archived: [])
        await beta.setLists(active: [review("prr_b_new")], archived: [])
        // Failure of Archived must not install only the new Active response.
        await beta.setListError(SyntheticPRReviewFleetError.offline, scope: "archived")
        await index.refresh()
        #expect(index.active.map(\.review.id) == ["prr_a_new", "prr_b"])
        #expect(index.archived.map(\.review) == [archived])
        #expect(index.notices.map(\.machineID) == ["host-b"])

        await beta.setListError(nil)
        await index.refresh()
        #expect(index.active.map(\.review.id) == ["prr_a_new", "prr_b_new"])
        #expect(index.archived.isEmpty)
        #expect(index.notices.isEmpty)
    }

    @Test("Cancellation errors do not become host notices", arguments: [false, true])
    func cancellationIsIgnored(urlCancellation: Bool) async {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha)], identity: 1)
        await index.refresh()
        await alpha.setListError(urlCancellation ? URLError(.cancelled) : CancellationError())
        await index.refresh()
        #expect(index.active.map(\.review.id) == ["prr_a"])
        #expect(index.notices.isEmpty)
        #expect(!index.isRefreshing)
    }

    @Test("Cancelled tasks reject successful responses that arrive late")
    func cancelledRefreshRejectsResponse() async throws {
        let gate = PRReviewFleetGate()
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_late")], listGates: ["active": gate])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha)], identity: 1)
        let refresh = Task { await index.refresh() }
        defer { refresh.cancel() }
        try await gate.waitForRequest()
        refresh.cancel()
        await gate.release()
        await refresh.value
        #expect(index.active.isEmpty)
        #expect(index.notices.isEmpty)
        #expect(!index.isRefreshing)
        #expect(!index.hasLoaded)
    }

    @Test("A superseded generation cannot replace the new client's lists")
    func supersededGenerationRejectsLateResponse() async throws {
        let gate = PRReviewFleetGate()
        let old = SyntheticPRReviewFleetClient(active: [review("prr_stale")], listGates: ["active": gate])
        let current = SyntheticPRReviewFleetClient(active: [review("prr_current")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", old)], identity: "old")
        let refresh = Task { await index.refresh() }
        defer { refresh.cancel() }
        try await gate.waitForRequest()
        index.setSources([source("host-a", "Alpha", current)], identity: "current")
        #expect(!index.isRefreshing)
        await index.refresh()
        await gate.release()
        await refresh.value
        #expect(index.active.map(\.review.id) == ["prr_current"])
        #expect(index.notices.isEmpty)
        #expect(index.hasLoaded && !index.isRefreshing)
    }

    @Test("Late failures cannot add notices or clear a newer refresh's progress")
    func supersededFailureDoesNotClobberProgress() async throws {
        let oldGate = PRReviewFleetGate()
        let newGate = PRReviewFleetGate()
        let old = SyntheticPRReviewFleetClient(listGates: ["active": oldGate])
        await old.setListError(SyntheticPRReviewFleetError.offline, scope: "active")
        let current = SyntheticPRReviewFleetClient(active: [review("prr_current")], listGates: ["active": newGate])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", old)], identity: "old")
        let oldRefresh = Task { await index.refresh() }
        defer { oldRefresh.cancel() }
        try await oldGate.waitForRequest()
        index.setSources([source("host-a", "Alpha", current)], identity: "new")
        let newRefresh = Task { await index.refresh() }
        defer { newRefresh.cancel() }
        try await newGate.waitForRequest()
        await oldGate.release()
        await oldRefresh.value
        #expect(index.isRefreshing)
        #expect(index.notices.isEmpty)
        #expect(!index.hasLoaded)
        await newGate.release()
        await newRefresh.value
        #expect(index.active.map(\.review.id) == ["prr_current"])
        #expect(!index.isRefreshing)
    }

    @Test("Unchanged identity retains the clients and does not interrupt refresh")
    func sameIdentityIsNoOp() async throws {
        let gate = PRReviewFleetGate()
        let original = SyntheticPRReviewFleetClient(active: [review("prr_original")], listGates: ["active": gate])
        let replacement = SyntheticPRReviewFleetClient(active: [review("prr_replacement")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", original)], identity: "same")
        let refresh = Task { await index.refresh() }
        defer { refresh.cancel() }
        try await gate.waitForRequest()
        index.setSources([source("host-a", "Ignored rename", replacement)], identity: "same")
        #expect(index.isRefreshing)
        // Overlapping refreshes of the same generation do not duplicate traffic.
        await index.refresh()
        await gate.release()
        await refresh.value
        #expect(index.active.first?.review.id == "prr_original")
        #expect(index.active.first?.machineName == "Alpha")
        #expect(await original.listScopes.count == 2)
        #expect(await replacement.listScopes.isEmpty)
        index.setSources([], identity: "same")
        #expect(index.hasLoaded)
        #expect(index.sourceCount == 1)
    }

    @Test("Roster reorder and rename preserve cached entries and notices")
    func reorderAndRenameCachedHosts() async {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")])
        let beta = SyntheticPRReviewFleetClient(active: [review("prr_b")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        await index.refresh()
        await alpha.setListError(SyntheticPRReviewFleetError.offline)
        await index.refresh()
        index.setSources([source("host-b", "Beta", beta), source("host-a", "Renamed Alpha", alpha)], identity: 2)
        #expect(index.active.map(\.review.id) == ["prr_b", "prr_a"])
        #expect(index.active.map(\.machineName) == ["Beta", "Renamed Alpha"])
        #expect(index.notices.first?.machineName == "Renamed Alpha")
        #expect(!index.hasLoaded)
    }

    @Test("Removing a source immediately drops both lists and its notice")
    func removalDropsEntriesAndNotices() async {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")], archived: [review("prr_a_old", archived: true)])
        let beta = SyntheticPRReviewFleetClient(active: [review("prr_b")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        await index.refresh()
        await alpha.setListError(SyntheticPRReviewFleetError.offline)
        await index.refresh()
        index.setSources([source("host-b", "Beta", beta)], identity: 2)
        #expect(index.sourceCount == 1)
        #expect(index.active.map(\.review.id) == ["prr_b"])
        #expect(index.archived.isEmpty)
        #expect(index.notices.isEmpty)
        #expect(!index.contains(target("host-a", "prr_a")))
        index.setSources([], identity: 3)
        await index.refresh()
        #expect(index.active.isEmpty && index.archived.isEmpty && index.notices.isEmpty)
        #expect(index.sourceCount == 0 && index.hasLoaded && !index.isRefreshing)
    }

    @Test("Archive, unarchive and refresh target only the owning machine and preserve row order")
    func actionsRouteToOwner() async throws {
        let shared = review("prr_shared")
        let alpha = SyntheticPRReviewFleetClient(active: [shared])
        let beta = SyntheticPRReviewFleetClient(active: [review("prr_before"), shared, review("prr_after")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        await index.refresh()
        let owner = target("host-b", "prr_shared")
        try await index.refreshReview(owner)
        #expect(index.active.filter { $0.machineID == "host-b" }.map(\.review.id) == ["prr_before", "prr_shared", "prr_after"])
        #expect(index.entry(for: owner)?.review.title == "Refreshed Synthetic prr_shared")
        #expect(index.entry(for: target("host-a", "prr_shared"))?.review == shared)

        try await index.archive(owner, archived: true)
        #expect(index.active.map(\.id) == [target("host-a", "prr_shared"), target("host-b", "prr_before"), target("host-b", "prr_after")])
        #expect(index.archived.map(\.id) == [owner])
        #expect(index.entry(for: owner)?.review.archivedAt != nil)
        #expect(index.contains(owner))
        try await index.refreshReview(owner)
        #expect(index.archived.map(\.id) == [owner])
        try await index.archive(owner, archived: false)
        #expect(index.archived.isEmpty)
        #expect(index.entry(for: owner)?.review.archivedAt == nil)
        #expect(await alpha.archiveRequests.isEmpty)
        #expect(await alpha.refreshRequests.isEmpty)
        let archives = await beta.archiveRequests
        let refreshes = await beta.refreshRequests
        #expect(archives.map(\.reviewID) == ["prr_shared", "prr_shared"])
        #expect(archives.map(\.archived) == [true, false])
        #expect(refreshes.map(\.reviewID) == ["prr_shared", "prr_shared"])
        let requestIDs = archives.map(\.requestID) + refreshes.map(\.requestID)
        #expect(requestIDs.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(requestIDs).count == requestIDs.count)
        #expect(await alpha.listScopes.count == 2)
        #expect(await beta.listScopes.count == 2)
    }

    @Test("Fleet archive forgets only the exact owner's local walkthrough after success", arguments: [false, true])
    func fleetArchiveForgetsOnlyOwnerProgress(targetIsOpen: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-walkthrough-\(UUID().uuidString).json")
        let domain = "PRReviewFleetArchiveTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: domain)
        }
        let snapshot = PRReviewDemo.snapshot()
        let shared = snapshot.review
        let owner = target("host-b", shared.id)
        let session = PRReviewGuideSession(persistenceURL: url)
        let shell = HerdrShellState(userDefaults: defaults, prReviewGuide: session)
        defer { session.suspend() }
        let scopes = [
            PRReviewGuideScope(machineID: "host-a", reviewID: shared.id, baseSHA: shared.baseSHA, headSHA: shared.headSHA),
            PRReviewGuideScope(machineID: "host-b", reviewID: shared.id, baseSHA: shared.baseSHA, headSHA: shared.headSHA),
            PRReviewGuideScope(machineID: "host-b", reviewID: "prr_other", baseSHA: shared.baseSHA, headSHA: shared.headSHA),
        ]
        let saved = scopes.map { scope in
            PRReviewGuideSession.Saved(
                scope: scope, plan: PRReviewGuideDemo.make(scope: scope),
                checkpoint: .init(chapter: 1, segment: 0, time: 0, voice: "af_jessica"),
                transcript: [.init(id: "synthetic-answer", question: "Why this change?",
                                   answer: PRReviewGuideDemo.make(scope: scope, question: "Why this change?"))]
            )
        }
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        let original = try Data(contentsOf: url)
        shell.prReview.configure(client: TestPRReviewClient(), machineID: targetIsOpen ? "host-b" : "host-a", demo: false)
        shell.prReview.selectedReviewID = shared.id
        shell.prReview.snapshot = snapshot
        session.configure(store: shell.prReview)
        #expect(session.plan != nil && session.transcript.count == 1)
        #expect(session.chapterIndex == 1)
        let openPlan = session.plan
        let alpha = SyntheticPRReviewFleetClient(active: [shared])
        let beta = SyntheticPRReviewFleetClient(active: [shared])
        shell.prReviewFleet.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)

        // Unarchive and a failed archive must preserve both saved and open state.
        try await shell.archivePRReviewFromFleet(owner, archived: false)
        #expect(try Data(contentsOf: url) == original)
        #expect(session.plan == openPlan && session.transcript.count == 1)
        await beta.setActionError(SyntheticPRReviewFleetError.offline)
        await #expect(throws: SyntheticPRReviewFleetError.offline) {
            try await shell.archivePRReviewFromFleet(owner, archived: true)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(session.plan == openPlan && session.transcript.count == 1)

        await beta.setActionError(nil)
        try await shell.archivePRReviewFromFleet(owner, archived: true)
        let remaining = try JSONDecoder().decode([PRReviewGuideSession.Saved].self, from: Data(contentsOf: url))
        #expect(remaining.map(\.scope) == [scopes[0], scopes[2]])
        #expect(remaining.allSatisfy { $0.transcript.count == 1 && $0.checkpoint.chapter == 1 })
        if targetIsOpen {
            #expect(session.plan == nil && session.transcript.isEmpty)
            #expect(!session.isPlaying && !session.isBusy && !session.isLoadingAudio)
        } else {
            #expect(session.plan == openPlan && session.transcript.count == 1)
            #expect(session.chapterIndex == 1)
        }
        #expect(await alpha.archiveRequests.isEmpty)
        #expect(await beta.archiveRequests.map(\.archived) == [false, true, true])
    }

    @Test("Event refresh updates the open detail without waiting for a slow fleet host")
    func eventRefreshDoesNotWaitForFleet() async throws {
        let domain = "PRReviewFleetRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let shell = HerdrShellState(userDefaults: defaults)
        let gate = PRReviewFleetGate()
        let slow = SyntheticPRReviewFleetClient(active: [review("prr_slow")], listGates: ["active": gate])
        let detailClient = SyntheticPRReviewWindowClient()
        shell.prReviewFleet.setSources([source("host-b", "Beta", slow)], identity: 1)
        shell.prReview.configure(client: detailClient, machineID: "host-a", demo: false)
        shell.prReview.selectedReviewID = PRReviewDemo.reviewID
        shell.prReview.hasLoaded = true
        shell.detailScope = .prReview
        let refresh = Task { await shell.refreshPRReviews(refreshFleet: true) }
        defer { refresh.cancel() }
        try await gate.waitForRequest()
        try await waitUntil { shell.prReview.snapshot != nil }
        #expect(shell.prReview.snapshot?.review.id == PRReviewDemo.reviewID)
        #expect(shell.prReviewFleet.isRefreshing)
        #expect(!shell.prReviewFleet.hasLoaded)
        await gate.release()
        await refresh.value
        #expect(shell.prReviewFleet.hasLoaded)
        #expect(await detailClient.reviewIDs == [PRReviewDemo.reviewID, PRReviewDemo.reviewID])
    }

    @Test("Event refresh does not poll a hidden fleet")
    func eventRefreshSkipsHiddenFleet() async throws {
        let domain = "PRReviewHiddenFleetRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let shell = HerdrShellState(userDefaults: defaults)
        let client = SyntheticPRReviewFleetClient(active: [review("prr_hidden")])
        shell.prReviewFleet.setSources([source("host-b", "Beta", client)], identity: 1)
        await shell.refreshPRReviews(refreshFleet: false)
        #expect(await client.listScopes.isEmpty)
        #expect(!shell.prReviewFleet.hasLoaded)
    }

    @Test("Missing owners reject mutations without using another companion")
    func missingOwnerThrows() async {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_shared")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha)], identity: 1)
        let missing = target("host-b", "prr_shared")
        await #expect(throws: APIError.self) { try await index.archive(missing, archived: true) }
        await #expect(throws: APIError.self) { try await index.refreshReview(missing) }
        index.setSources([], identity: 2)
        do {
            try await index.archive(target("host-a", "prr_shared"), archived: true)
            Issue.record("A removed owner must reject archive")
        } catch {
            if case APIError.invalidResponse = error { /* Expected. */ }
            else { Issue.record("Expected APIError.invalidResponse") }
        }
        do {
            try await index.refreshReview(target("host-a", "prr_shared"))
            Issue.record("A removed owner must reject refresh")
        } catch {
            if case APIError.invalidResponse = error { /* Expected. */ }
            else { Issue.record("Expected APIError.invalidResponse") }
        }
        #expect(await alpha.archiveRequests.isEmpty)
        #expect(await alpha.refreshRequests.isEmpty)
    }

    @Test("Failed actions retain the row and propagate their error", arguments: ["archive", "refresh"])
    func failedActionsRetainEntry(action: String) async throws {
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha)], identity: 1)
        await index.refresh()
        let before = index.active
        await alpha.setActionError(SyntheticPRReviewFleetError.offline)
        await #expect(throws: SyntheticPRReviewFleetError.offline) {
            if action == "archive" { try await index.archive(target("host-a", "prr_a"), archived: true) }
            else { try await index.refreshReview(target("host-a", "prr_a")) }
        }
        #expect(index.active == before)
        #expect(index.archived.isEmpty)
    }

    @Test("Late mutations cannot repopulate a removed owner", arguments: ["archive", "refresh"])
    func staleMutationsAreRejected(action: String) async throws {
        let gate = PRReviewFleetGate()
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_a")], actionGate: gate)
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha)], identity: 1)
        await index.refresh()
        let mutation = Task {
            if action == "archive" { try await index.archive(target("host-a", "prr_a"), archived: true) }
            else { try await index.refreshReview(target("host-a", "prr_a")) }
        }
        defer { mutation.cancel() }
        try await gate.waitForRequest()
        index.setSources([], identity: 2)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await mutation.value }
        #expect(index.active.isEmpty && index.archived.isEmpty)
    }

    @Test("A list fetched before archive cannot put the review back")
    func staleListCannotUndoArchive() async throws {
        let gate = PRReviewFleetGate()
        let alpha = SyntheticPRReviewFleetClient(active: [review("prr_shared")], listGates: ["active": gate])
        let beta = SyntheticPRReviewFleetClient(active: [review("prr_shared")])
        let index = PRReviewFleetIndex()
        index.setSources([source("host-a", "Alpha", alpha), source("host-b", "Beta", beta)], identity: 1)
        let refresh = Task { await index.refresh() }
        defer { refresh.cancel() }
        try await gate.waitForRequest()
        try await index.archive(target("host-a", "prr_shared"), archived: true)
        await gate.release()
        await refresh.value
        #expect(index.active.map(\.id) == [target("host-b", "prr_shared")])
        #expect(index.archived.map(\.id) == [target("host-a", "prr_shared")])
    }

    private func review(_ id: String, title: String? = nil, archived: Bool = false) -> PRReviewSummary {
        var review = fleetSnapshot().review
        review.id = id
        review.title = title ?? "Synthetic \(id)"
        review.archivedAt = archived ? "2026-01-01T00:00:00Z" : nil
        return review
    }

    private func source(_ id: String, _ name: String, _ client: any PRReviewClient) -> PRReviewFleetSource {
        .init(machineID: id, machineName: name, client: client)
    }

    private func target(_ machineID: String, _ reviewID: String) -> PRReviewWindowTarget {
        .init(machineID: machineID, reviewID: reviewID)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else { throw SyntheticPRReviewFleetError.timedOut }
            try await clock.sleep(for: .milliseconds(2))
        }
    }
}

/// Fixed synthetic data, with no clocks, network requests or captured reviews.
private func fleetSnapshot() -> PRReviewSnapshot {
    try! JSONDecoder().decode(PRReviewSnapshot.self, from: Data("""
    {"ok":true,"review":{"id":"prr_fixture","url":"https://host-a.example.invalid/example/garden/pull/7","number":7,"title":"Synthetic fixture","status":"ready","revision":1}}
    """.utf8))
}

private enum SyntheticPRReviewFleetError: LocalizedError, Equatable {
    case offline
    case timedOut

    var errorDescription: String? {
        switch self {
        case .offline: "Synthetic companion is offline."
        case .timedOut: "Synthetic request did not arrive before the test deadline."
        }
    }
}

/// A bounded request gate. Cancellation releases pending requests, so a
/// regression fails the test rather than leaving its task group hanging.
private actor PRReviewFleetGate {
    private var response: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { response = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForRequest() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while response == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SyntheticPRReviewFleetError.timedOut }
            try await clock.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        response?.resume()
        response = nil
    }

    private func cancel() {
        response?.resume(throwing: CancellationError())
        response = nil
    }
}

/// An entirely in-memory companion. The actor records requests and returns
/// fixed host-specific summaries, including list responses captured before a
/// gate so tests can reproduce late polling without timing assumptions.
private actor SyntheticPRReviewFleetClient: PRReviewClient {
    struct ArchiveRequest: Sendable {
        let reviewID: String
        let archived: Bool
        let requestID: String
    }
    struct RefreshRequest: Sendable {
        let reviewID: String
        let requestID: String
    }

    private var active: [PRReviewSummary]
    private var archived: [PRReviewSummary]
    private var listError: (any Error)?
    private var errorScope: String?
    private var actionError: (any Error)?
    private let listGates: [String: PRReviewFleetGate]
    private let actionGate: PRReviewFleetGate?
    private(set) var listScopes: [String] = []
    private(set) var archiveRequests: [ArchiveRequest] = []
    private(set) var refreshRequests: [RefreshRequest] = []

    init(active: [PRReviewSummary] = [], archived: [PRReviewSummary] = [],
         listGates: [String: PRReviewFleetGate] = [:], actionGate: PRReviewFleetGate? = nil) {
        self.active = active
        self.archived = archived
        self.listGates = listGates
        self.actionGate = actionGate
    }

    func setLists(active: [PRReviewSummary], archived: [PRReviewSummary]) {
        self.active = active
        self.archived = archived
    }
    func setListError(_ error: (any Error)?, scope: String? = nil) {
        listError = error
        errorScope = scope
    }
    func setActionError(_ error: (any Error)?) { actionError = error }

    func prReviews(scope: String) async throws -> [PRReviewSummary] {
        listScopes.append(scope)
        let values = scope == "archived" ? archived : active
        let error = errorScope == nil || errorScope == scope ? listError : nil
        if let gate = listGates[scope] { try await gate.wait() }
        if let error { throw error }
        return values
    }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot {
        archiveRequests.append(.init(reviewID: id, archived: archived, requestID: requestID))
        if let actionGate { try await actionGate.wait() }
        if let actionError { throw actionError }
        guard var review = (active + self.archived).first(where: { $0.id == id }) else { throw APIError.invalidResponse }
        review.archivedAt = archived ? "2026-01-02T00:00:00Z" : nil
        review.revision += 1
        active.removeAll { $0.id == id }
        self.archived.removeAll { $0.id == id }
        if archived { self.archived.insert(review, at: 0) }
        else { active.insert(review, at: 0) }
        var snapshot = fleetSnapshot()
        snapshot.review = review
        return snapshot
    }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot {
        refreshRequests.append(.init(reviewID: id, requestID: requestID))
        if let actionGate { try await actionGate.wait() }
        if let actionError { throw actionError }
        guard var review = (active + archived).first(where: { $0.id == id }) else { throw APIError.invalidResponse }
        review.title = "Refreshed \(review.title)"
        review.revision += 1
        if let index = active.firstIndex(where: { $0.id == id }) { active[index] = review }
        if let index = archived.firstIndex(where: { $0.id == id }) { archived[index] = review }
        var snapshot = fleetSnapshot()
        snapshot.review = review
        return snapshot
    }

    // Unused endpoints refuse calls rather than hiding unexpected traffic.
    func prReviewCapabilities() async throws -> PRReviewCapabilities { throw APIError.invalidResponse }
    func prReviewSkills() async throws -> [PRReviewSkill] { throw APIError.invalidResponse }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { throw APIError.invalidResponse }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { throw APIError.invalidResponse }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func prReview(id: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { throw APIError.invalidResponse }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText { throw APIError.invalidResponse }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { throw APIError.invalidResponse }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func finishPRReviewRun(reviewID: String, runID: String, state: PRReviewRunState, note: String?, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { throw APIError.invalidResponse }
    func markPRReviewSkill(reviewID: String, skillID: String, state: String, note: String?, requestID: String) async throws -> PRReviewSkillState { throw APIError.invalidResponse }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary { throw APIError.invalidResponse }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func setPRReviewViewed(id: String, paths: [String], viewed: Bool, requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { throw APIError.invalidResponse }
    func addPRReviewDocument(id: String, payload: PRReviewDocumentPayload, requestID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws { throw APIError.invalidResponse }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { throw APIError.invalidResponse }
}
