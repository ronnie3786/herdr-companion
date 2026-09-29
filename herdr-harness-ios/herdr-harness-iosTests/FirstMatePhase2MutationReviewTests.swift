import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Phase 2 mutation review", .serialized)
@MainActor
struct FirstMatePhase2MutationReviewTests {
    private func source(_ client: Phase2MutationClient, token: String = "synthetic") -> FirstMateMobileFleetSource {
        let machine = ChatFixtures.machine("alpha")
        return .init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: token), client: client)
    }
    private func setup(_ client: Phase2MutationClient) async -> HerdrAppModel {
        let defaults = UserDefaults(suiteName: "Phase2Mutations.\(UUID())")!
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults,
                                  bootstrapMachines: [ChatFixtures.machine("alpha")])
        model.hasCompletedSetup = true
        model.firstMateFleet.activate(sources: [source(client)], connectionGeneration: model.connectionGeneration)
        await model.firstMateFleet.refreshAll()
        return model
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "phase2 mutation review") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Archive freshness permits remote index-only unarchive without a workflow revision change")
    func remoteUnarchive() async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "A")
        let store = try #require(fleet.store(for: target))
        let revision = try #require(store.snapshots["A"]?.feature.revision)
        #expect(await fleet.setArchived(target, archived: true, expectedContext: store.operationContext))
        #expect(fleet.open(.init(machineID: "alpha", featureID: "B")))
        let context = store.operationContext
        store.draft = "B stays selected"
        let reads = await client.featureReads["A", default: 0]
        await client.remoteArchive("A", archived: false)
        await fleet.refreshChatIndex()
        #expect(await client.current("A").feature.revision == revision)
        #expect(store.snapshots["A"]?.feature.isArchived == true, "Only the index refreshed")
        #expect(fleet.conversations.contains { $0.featureID == "A" })
        #expect(fleet.badgeCount == 1)
        #expect(store.operationContext == context && store.draft == "B stays selected")
        #expect(await client.featureReads["A", default: 0] == reads)
    }

    @Test("Replacing a source cannot carry the previous owner's archive tombstone")
    func archiveSourceReplacement() async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let store = try #require(fleet.store(forMachineID: "alpha"))
        #expect(await fleet.setArchived(.init(machineID: "alpha", featureID: "A"), archived: true, expectedContext: store.operationContext))
        let replacement = Phase2MutationClient()
        fleet.activate(sources: [source(replacement, token: "new-owner")], connectionGeneration: model.connectionGeneration)
        await fleet.refreshChatIndex()
        #expect(fleet.conversations.contains { $0.featureID == "A" })
        #expect(fleet.store(forMachineID: "alpha") !== store)
    }

    @Test("Real unarchive failure and retry update the separate list banner, not just store.error")
    func unarchiveFeedbackIntegration() async throws {
        let client = Phase2MutationClient()
        await client.remoteArchive("A", archived: true)
        let model = await setup(client), fleet = model.firstMateFleet
        fleet.setShowArchived(true)
        await fleet.refreshAll()
        let store = try #require(fleet.store(forMachineID: "alpha"))
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "A")
        let feedback = FirstMateListMutationFeedback()
        await client.setArchiveFailure(true)
        let first = feedback.begin(target: target, store: store)
        let failed = await fleet.setArchived(target, archived: false, expectedContext: store.operationContext)
        feedback.complete(first, succeeded: failed, error: store.error, fleet: fleet)
        #expect(!failed && feedback.message(in: fleet) == "Synthetic unarchive failure")
        await fleet.refreshAll()
        #expect(store.error == nil && feedback.message(in: fleet) == "Synthetic unarchive failure")
        await client.setArchiveFailure(false)
        let retry = feedback.begin(target: target, store: store)
        #expect(feedback.message(in: fleet) == nil)
        let succeeded = await fleet.setArchived(target, archived: false, expectedContext: store.operationContext)
        feedback.complete(retry, succeeded: succeeded, error: store.error, fleet: fleet)
        #expect(succeeded && feedback.message(in: fleet) == nil)
        #expect(fleet.conversations.contains { $0.featureID == "A" })
    }

    @Test("A held pre-archive poll cannot resurrect a confirmed local archive")
    func heldPreArchivePoll() async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let gate = Phase2MutationGate()
        await client.holdNextIndex(gate)
        let polling = Task { await fleet.refreshChatIndex() }
        defer { polling.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        let store = try #require(fleet.store(forMachineID: "alpha"))
        #expect(await fleet.setArchived(.init(machineID: "alpha", featureID: "A"), archived: true, expectedContext: store.operationContext))
        await gate.open(); await polling.value
        #expect(!fleet.conversations.contains { $0.featureID == "A" })
        #expect(store.snapshots["A"]?.feature.revision == 7)
        #expect(store.snapshots["A"]?.feature.isArchived == true)
    }

    @Test("Creation selection obeys cancellation, navigation and exact connection ownership",
          arguments: ["normal", "tab", "pane", "cancel", "replace", "remove"])
    func creationOwnership(_ outcome: String) async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let gate = Phase2MutationGate()
        await client.holdCreate(gate)
        let store = try #require(fleet.store(forMachineID: "alpha"))
        let original = FirstMateFeatureTarget(machineID: "alpha", featureID: "A")
        #expect(fleet.open(original))
        store.draft = "Original draft"
        let context = store.operationContext, intent = model.beginAppNavigation()
        let creating = Task { await fleet.create(on: "alpha", title: "Frozen title", goal: "Frozen goal", cwd: "/workspace/alpha",
            requestID: "frozen-id", expectedContext: context, navigationIntent: intent) }
        defer { creating.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        switch outcome {
        case "tab": model.selectTab(.notes)
        case "pane":
            model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "alpha") }
            let pane = try #require(model.workspaces.first?.panes.first)
            model.openPane(id: pane.id)
        case "cancel": creating.cancel()
        case "replace": fleet.activate(sources: [source(Phase2MutationClient(), token: "replacement")], connectionGeneration: model.connectionGeneration)
        case "remove": fleet.activate(sources: [], connectionGeneration: model.connectionGeneration)
        default: break
        }
        await gate.open()
        let target = await creating.value
        if outcome == "replace" || outcome == "remove" {
            #expect(target == nil && store.snapshots["C"] == nil)
        } else {
            #expect(target == .init(machineID: "alpha", featureID: "C"))
            #expect(store.snapshots["C"]?.feature.goal == "Frozen goal")
            if outcome == "normal" {
                #expect(fleet.selectedTarget == target && store.selectedFeatureID == "C")
            } else {
                #expect(fleet.selectedTarget == original && store.operationContext == context)
                #expect(store.draft == "Original draft")
            }
        }
        #expect(!store.isSending)
        #expect(await client.creates == [.init(title: "Frozen title", goal: "Frozen goal", cwd: "/workspace/alpha", requestID: "frozen-id")])
    }

    @Test("A superseded sheet intent cannot dispatch a queued creation on a newer tab")
    func creationBeforeDispatch() async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let store = try #require(fleet.store(forMachineID: "alpha"))
        let context = store.operationContext, intent = model.beginAppNavigation()
        model.selectTab(.notes)
        #expect(await fleet.create(on: "alpha", title: "No send", goal: "No send", cwd: "/workspace/alpha", requestID: "no-send",
                                   expectedContext: context, navigationIntent: intent) == nil)
        #expect(await client.creates.isEmpty)
    }

    @Test("Archive timestamp ordering is chronological and never inferred from workflow revision")
    func archiveOrdering() {
        var cached = ChatFixtures.feature("A", archived: true)
        cached.updatedAt = "2030-01-01T00:00:00.500Z"
        var active = cached
        active.archivedAt = nil; active.revision += 100
        active.updatedAt = "2030-01-01T00:00:00Z"
        #expect(!FirstMateMobileListPresentation.activeInventorySupersedesArchive(active, cached: cached))
        active.revision = cached.revision
        active.updatedAt = "2030-01-01T00:00:01Z"
        #expect(FirstMateMobileListPresentation.activeInventorySupersedesArchive(active, cached: cached))
        active.updatedAt = "not-a-time"
        #expect(!FirstMateMobileListPresentation.activeInventorySupersedesArchive(active, cached: cached))
    }

    @Test("A deferred create cannot select over same-host B during the result refresh")
    func creationDoesNotStealNewSelection() async throws {
        let client = Phase2MutationClient(), model = await setup(client), fleet = model.firstMateFleet
        let createGate = Phase2MutationGate(), refreshGate = Phase2MutationGate()
        await client.holdCreate(createGate, resultRefresh: refreshGate)
        let store = try #require(fleet.store(forMachineID: "alpha"))
        #expect(fleet.open(.init(machineID: "alpha", featureID: "A")))
        let context = store.operationContext
        let intent = model.beginAppNavigation()
        let creating = Task { await fleet.create(on: "alpha", title: "Frozen C", goal: "Frozen goal", cwd: "/workspace/alpha",
                                                requestID: "one-request", expectedContext: context, navigationIntent: intent) }
        defer { creating.cancel(); Task { await createGate.open(); await refreshGate.open() } }
        try await wait { await createGate.arrivals > 0 }
        #expect(store.isSending)
        let url = try #require(URL(string: "herdr://first-mate?feature_id=B&server_url=https%3A%2F%2Falpha.example.invalid"))
        let request = try #require(FirstMateMobileOpenRequest(url: url))
        await model.openFirstMate(request, sources: [source(client)]).value
        let targetB = FirstMateFeatureTarget(machineID: "alpha", featureID: "B")
        #expect(fleet.selectedTarget == targetB)
        store.draft = "Keep B's newer draft"
        let contextB = store.operationContext
        let lease = FirstMateWorkspaceControlLease()
        lease.update(store: store, available: true)
        defer { lease.release() }
        await createGate.open()
        try await wait { await refreshGate.arrivals > 0 }
        #expect(fleet.selectedTarget == targetB)
        #expect(store.selectedFeatureID == "B" && store.operationContext == contextB)
        #expect(store.draft == "Keep B's newer draft")
        #expect(store.controlAvailable && store.operationContext.matchesFeature("B"))
        #expect(store.snapshots["C"]?.feature.title == "Frozen C")
        let beforePoll = await client.featureReads["B", default: 0]
        await fleet.refreshSelected(targetB)
        #expect(await client.featureReads["B", default: 0] > beforePoll)
        await refreshGate.open()
        #expect(await creating.value == .init(machineID: "alpha", featureID: "C"))
        #expect(fleet.selectedTarget == targetB && store.operationContext == contextB)
        #expect(store.draft == "Keep B's newer draft")
        let calls = await client.creates
        #expect(calls == [.init(title: "Frozen C", goal: "Frozen goal", cwd: "/workspace/alpha", requestID: "one-request")])
    }
}

actor Phase2MutationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

actor Phase2MutationClient: FirstMateClient {
    struct Creation: Equatable, Sendable { let title: String; let goal: String; let cwd: String; let requestID: String }
    private var snapshots: [String: FirstMateSnapshot]
    private var tick = 0
    private var archiveFailure = false
    func setArchiveFailure(_ value: Bool) { archiveFailure = value }
    private var indexGate: Phase2MutationGate?
    private var nextListGate: Phase2MutationGate?
    private var createGate: Phase2MutationGate?
    private var resultRefreshGate: Phase2MutationGate?
    private(set) var creates: [Creation] = []
    private(set) var featureReads: [String: Int] = [:]
    init() {
        snapshots = Dictionary(uniqueKeysWithValues: ["A", "B"].map { id in
            var feature = ChatFixtures.feature(id, status: id == "A" ? "blocked" : "completed")
            feature.revision = 7; feature.updatedAt = "2030-01-01T00:00:00Z"
            return (id, FirstMateSnapshot(feature: feature))
        })
    }
    func current(_ id: String) -> FirstMateSnapshot { snapshots[id]! }
    func holdNextIndex(_ gate: Phase2MutationGate) { indexGate = gate }
    func holdCreate(_ gate: Phase2MutationGate, resultRefresh: Phase2MutationGate? = nil) { createGate = gate; resultRefreshGate = resultRefresh }
    func remoteArchive(_ id: String, archived: Bool) {
        tick += 1
        snapshots[id]?.feature.archivedAt = archived ? "2030-01-01T00:00:00Z" : nil
        snapshots[id]?.feature.updatedAt = String(format: "2030-01-01T00:00:%02dZ", tick)
        // Production archive mutation changes timestamp/archive fields, never workflow revision.
    }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-fleet-v1", "first-mate-archive-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { await list(scope: .active, isIndex: true) }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList { await list(scope: scope, isIndex: false) }
    private func list(scope: FirstMateFeatureScope, isIndex: Bool) async -> FirstMateFeatureList {
        let result = snapshots.values.map(\.feature).filter { scope == .all || !$0.isArchived }.sorted { $0.id < $1.id }
        let gate = nextListGate ?? (isIndex ? indexGate : nil)
        if nextListGate != nil { nextListGate = nil } else if isIndex { indexGate = nil }
        await gate?.wait()
        return .init(ok: true, features: result)
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        .init(features: snapshots.values.filter { !$0.feature.isArchived }.map { value in
            .init(featureID: value.feature.id, title: value.feature.title, status: value.feature.status,
                  hudStatus: value.feature.status == "blocked" ? .blocked : .done,
                  latestFirstMateMessageID: "reply-" + value.feature.id, unread: value.feature.status == "blocked")
        })
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        featureReads[id, default: 0] += 1
        guard let value = snapshots[id] else { throw APIError.invalidResponse }
        return value
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        creates.append(.init(title: title, goal: goal, cwd: cwd, requestID: requestID))
        await createGate?.wait()
        let value = FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd, id: "C")
        snapshots["C"] = value
        nextListGate = resultRefreshGate
        return value
    }
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot {
        if archiveFailure { throw APIError.server(status: 503, message: "Synthetic unarchive failure") }
        remoteArchive(featureID, archived: archived)
        return snapshots[featureID]!
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
