import Foundation
import Observation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate fleet index")
@MainActor
struct FirstMateFleetIndexTests {
    @Test("Aggregate results keep duplicate feature IDs distinct and isolate partial failures")
    func aggregatePartialFailureAndSearch() async throws {
        let alpha = snapshot(id: "shared-feature", title: "Alpha launch", goal: "Ship the synthetic alpha")
        let beta = snapshot(id: "shared-feature", title: "Beta cleanup", goal: "Tidy the synthetic beta")
        let index = FirstMateFleetIndex()
        let sources = [
            source(id: "alpha", name: "Alpha Mac", token: "alpha-token", result: .success([alpha.feature])),
            source(id: "beta", name: "Beta Mac", token: "beta-token", result: .success([beta.feature])),
            source(id: "legacy", name: "Legacy Mac", token: "legacy-token", result: .failure(.server(status: 404, message: "Missing"))),
        ]

        let lifecycle = index.activate(sources: sources, connectionGeneration: 7)
        await index.refresh(lifecycle: lifecycle)

        #expect(index.hosts.count == 3)
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.features.map(\.id) == ["shared-feature"])
        #expect(index.hosts.first(where: { $0.id == "beta" })?.features.map(\.id) == ["shared-feature"])
        #expect(index.hosts.first(where: { $0.id == "legacy" })?.unsupported == true)
        #expect(FirstMateFleetFeatureID(machineID: "alpha", featureID: "shared-feature") != FirstMateFleetFeatureID(machineID: "beta", featureID: "shared-feature"))

        index.search = "alpha"
        #expect(index.filteredHosts.map(\.machineID) == ["alpha"])
        index.search = "cleanup"
        #expect(index.filteredHosts.map(\.machineID) == ["beta"])
    }

    @Test("Changed credentials, roster removal, and cancellation reject stale list results")
    func staleResultsAndConfigurationChanges() async throws {
        let oldGate = FirstMateFleetResponseGate()
        let oldMachine = machine(id: "host", name: "Host")
        let oldConfiguration = configuration(for: oldMachine, token: "old-token")
        let oldSource = FirstMateFleetSource(
            machine: oldMachine,
            configuration: oldConfiguration,
            client: SyntheticFleetClient { try await oldGate.fetch() }
        )
        let index = FirstMateFleetIndex()
        let oldLifecycle = index.activate(sources: [oldSource], connectionGeneration: 4)
        let oldRefresh = Task { await index.refresh(lifecycle: oldLifecycle) }
        defer {
            oldRefresh.cancel()
            Task { await oldGate.cancelPending() }
        }
        try await oldGate.waitForRequest()

        let current = snapshot(id: "current", title: "Current feature", goal: "Use the current credential")
        let newSource = source(id: "host", name: "Host", token: "new-token", result: .success([current.feature]))
        let newLifecycle = index.activate(sources: [newSource], connectionGeneration: 4)
        #expect(index.hosts.first?.features.isEmpty == true)
        await index.refresh(lifecycle: newLifecycle)
        await oldGate.succeed(with: [snapshot(id: "stale", title: "Stale feature", goal: "Never apply").feature])
        await oldRefresh.value
        #expect(index.hosts.first?.features.map(\.id) == ["current"])

        let cancelledGate = FirstMateFleetResponseGate()
        let cancelledSource = FirstMateFleetSource(
            machine: oldMachine,
            configuration: configuration(for: oldMachine, token: "cancel-token"),
            client: SyntheticFleetClient { try await cancelledGate.fetch() }
        )
        let cancelledLifecycle = index.activate(sources: [cancelledSource], connectionGeneration: 5)
        let cancelledRefresh = Task { await index.refresh(lifecycle: cancelledLifecycle) }
        defer {
            cancelledRefresh.cancel()
            Task { await cancelledGate.cancelPending() }
        }
        try await cancelledGate.waitForRequest()
        cancelledRefresh.cancel()
        await cancelledGate.succeed(with: [snapshot(id: "cancelled", title: "Cancelled result", goal: "Never apply").feature])
        await cancelledRefresh.value
        #expect(index.hosts.first?.features.isEmpty == true)

        _ = index.activate(sources: [], connectionGeneration: 5)
        #expect(index.hosts.isEmpty)
    }

    @Test("Per-host stores restore drafts and retired stores reject delayed operations")
    func detailStoreCacheAndEviction() async throws {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        let machineA = machine(id: "alpha", name: "Alpha")
        let machineB = machine(id: "beta", name: "Beta")
        let configurationA = configuration(for: machineA, token: "alpha-token")
        let configurationB = configuration(for: machineB, token: "beta-token")
        let snapshotA = snapshot(id: "shared", title: "Alpha feature", goal: "Alpha")
        let snapshotB = snapshot(id: "shared", title: "Beta feature", goal: "Beta")
        let clientA = SyntheticFleetClient(snapshot: snapshotA)
        let clientB = SyntheticFleetClient(snapshot: snapshotB)

        #expect(shell.configureFirstMateIfNeeded(machineID: machineA.id, configuration: configurationA, connectionGeneration: 9, isDemo: false, client: clientA))
        #expect(shell.isActiveFirstMateConnection(machineID: machineA.id, configuration: configurationA, connectionGeneration: 9, isDemo: false))
        let storeA = shell.firstMate
        storeA.receive(snapshotA)
        storeA.select(snapshotA.feature.id)
        storeA.draft = "alpha draft"
        storeA.isDark = false

        #expect(shell.configureFirstMateIfNeeded(machineID: machineB.id, configuration: configurationB, connectionGeneration: 9, isDemo: false, client: clientB))
        let storeB = shell.firstMate
        storeB.receive(snapshotB)
        storeB.select(snapshotB.feature.id)
        storeB.draft = "beta draft"
        #expect(storeB !== storeA)
        #expect(storeB.isDark == false)

        #expect(!shell.configureFirstMateIfNeeded(machineID: machineA.id, configuration: configurationA, connectionGeneration: 9, isDemo: false, client: clientA))
        #expect(shell.firstMate === storeA)
        #expect(shell.firstMate.draft == "alpha draft")
        #expect(shell.firstMate.snapshot?.feature.title == "Alpha feature")

        let oldStoreBContext = storeB.operationContext
        let changedConfigurationB = configuration(for: machineB, token: "rotated-beta-token")
        shell.reconcileFirstMateStores(
            configurations: [machineA.id: configurationA, machineB.id: changedConfigurationB],
            connectionGeneration: 9,
            isDemo: false
        )
        #expect(shell.isActiveFirstMateConnection(machineID: machineA.id, configuration: configurationA, connectionGeneration: 9, isDemo: false))
        #expect(!(await storeB.create(
            title: "Inactive delayed create",
            goal: "Must be rejected after inactive credential rotation",
            cwd: "/tmp/synthetic",
            requestID: "inactive-delayed-request",
            expectedContext: oldStoreBContext
        )))

        let oldContext = storeA.operationContext
        let changedConfigurationA = configuration(for: machineA, token: "rotated-alpha-token")
        #expect(!shell.isActiveFirstMateConnection(machineID: machineA.id, configuration: changedConfigurationA, connectionGeneration: 9, isDemo: false))
        shell.reconcileFirstMateStores(
            configurations: [machineA.id: changedConfigurationA, machineB.id: changedConfigurationB],
            connectionGeneration: 9,
            isDemo: false
        )
        #expect(shell.activeFirstMateMachineID == nil)
        #expect(!(await storeA.create(
            title: "Delayed create",
            goal: "Must be rejected after eviction",
            cwd: "/tmp/synthetic",
            requestID: "delayed-request",
            expectedContext: oldContext
        )))
        #expect(shell.configureFirstMateIfNeeded(machineID: machineA.id, configuration: changedConfigurationA, connectionGeneration: 9, isDemo: false, client: clientA))
        #expect(shell.isActiveFirstMateConnection(machineID: machineA.id, configuration: changedConfigurationA, connectionGeneration: 9, isDemo: false))

        _ = shell.configureFirstMateIfNeeded(machineID: machineB.id, configuration: changedConfigurationB, connectionGeneration: 9, isDemo: false, client: clientB)
        shell.reconcileFirstMateStores(configurations: [:], connectionGeneration: 9, isDemo: false)
        #expect(shell.activeFirstMateMachineID == nil)
        shell.reconcileFirstMateStores(configurations: [machineB.id: changedConfigurationB], connectionGeneration: 10, isDemo: false)
        #expect(shell.firstMate !== storeB)
    }

    @Test("Companion host defaults to All Machines without losing explicit host choices")
    func defaultCompanionHostScope() {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        let hosts = ["alpha", "beta"]
        #expect(shell.firstMateScope == .all)
        #expect(FirstMateMachineScope.resolved(shell.firstMateScope, availableMachineIDs: hosts) == .all)

        shell.selectFirstMateScope(.machine("beta"))
        #expect(FirstMateMachineScope.resolved(shell.firstMateScope, availableMachineIDs: hosts) == .machine("beta"))
        // Removing a saved host must not silently select a different host.
        #expect(FirstMateMachineScope.resolved(shell.firstMateScope, availableMachineIDs: ["alpha"]) == .all)
        #expect(FirstMateMachineScope.resolved(nil, availableMachineIDs: hosts) == .all)
        #expect(FirstMateMachineScope.resolved(nil, availableMachineIDs: []) == .all)
    }

    @Test("All Machines selection keeps aggregate scope and requires an exact create host")
    func aggregateScopeActions() throws {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        shell.selectFirstMateScope(.all)
        shell.openFirstMateFeatureFromFleet(machineID: "alpha", featureID: "shared")
        #expect(shell.firstMateScope == .all)
        #expect(shell.firstMateMachineID == "alpha")
        #expect(shell.pendingFirstMateControlTarget?.machineID == "alpha")

        shell.createFirstMateFeature(on: "beta")
        #expect(shell.firstMateScope == .all)
        #expect(shell.firstMateMachineID == "beta")
        #expect(shell.pendingFirstMateCreateMachineID == "beta")

        shell.selectFirstMateScope(.machine("alpha"))
        #expect(shell.pendingFirstMateControlTarget?.machineID == nil)
        #expect(shell.pendingFirstMateCreateMachineID == nil)
        shell.createFirstMateFeature(on: "beta")
        shell.openFirstMateFeatureFromFleet(machineID: "alpha", featureID: "new-selection")
        #expect(shell.pendingFirstMateCreateMachineID == nil)
        #expect(shell.pendingFirstMateControlTarget?.featureID == "new-selection")
    }

    @Test("Attention counts every host independently of search and unsupported hosts")
    func attentionUsesUnfilteredHosts() async throws {
        let index = FirstMateFleetIndex()
        let sources = [
            source(id: "alpha", name: "Alpha Mac", token: "alpha-token", result: .success([
                feature(id: "shared", status: "awaiting_direction"),
                feature(id: "shared", status: "blocked"),
                feature(id: "working", status: "running"),
            ])),
            source(id: "beta", name: "Beta Mac", token: "beta-token", result: .success([
                feature(id: "shared", status: "awaiting_direction"),
            ])),
            source(id: "legacy", name: "Legacy Mac", token: "legacy-token", result: .failure(.server(status: 404, message: "Missing"))),
        ]

        let lifecycle = index.activate(sources: sources, connectionGeneration: 11)
        #expect(index.attentionCount == 0)
        await index.refresh(lifecycle: lifecycle)
        #expect(index.attentionCount == 2)
        #expect(index.hosts.first(where: { $0.id == "legacy" })?.unsupported == true)

        index.search = "working"
        #expect(index.filteredHosts.flatMap(\.features).map(\.id) == ["working"])
        #expect(index.attentionCount == 2)

        index.search = "no synthetic feature matches this"
        #expect(index.filteredHosts.isEmpty)
        #expect(index.attentionCount == 2)
    }

    @Test("Polling applies successive responses without navigation")
    func pollingAppliesSuccessiveResponses() async throws {
        let gate = FirstMateFleetStepGate()
        let machine = machine(id: "alpha", name: "Alpha Mac")
        let index = FirstMateFleetIndex()
        index.pollingInterval = .milliseconds(5)
        let source = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "alpha-token"),
            client: SyntheticFleetClient { try await gate.fetch() }
        )
        let observation = Task { await index.observe(sources: [source], connectionGeneration: 12) }
        defer { observation.cancel() }
        try await gate.waitForFetch()

        await gate.supply(.init(ok: true, features: [
            feature(id: "one", status: "awaiting_direction"),
            feature(id: "two", status: "blocked"),
            feature(id: "three", status: "running"),
        ]))
        try await waitForFleetIndexCondition("initial attention") { index.attentionCount == 2 }
        #expect(index.hosts.first?.lastUpdated != nil)

        await gate.supply(.init(ok: true, features: [feature(id: "three", status: "running")]))
        try await waitForFleetIndexCondition("cleared attention") { index.attentionCount == 0 }

        await gate.supply(.init(ok: true, features: [feature(id: "four", status: "blocked")]))
        try await waitForFleetIndexCondition("renewed attention") { index.attentionCount == 1 }

        observation.cancel()
        await gate.cancelPending()
        await observation.value
        let fetches = await gate.fetchCount
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.fetchCount == fetches)
        #expect(index.hosts.first?.isLoading == false)
    }

    @Test("Failed hosts retain last-known attention while healthy hosts update")
    func transientFailuresRetainAttention() async throws {
        let index = FirstMateFleetIndex()
        let alphaScript = FirstMateFleetResponseScript([
            .success([feature(id: "alpha-direction", status: "awaiting_direction")]),
            .failure(.server(status: 500, message: "Temporarily unavailable")),
            .success([]),
        ])
        let betaScript = FirstMateFleetResponseScript([
            .success([feature(id: "beta-blocked", status: "blocked")]),
            .success([feature(id: "beta-working", status: "running")]),
        ])
        let alpha = machine(id: "alpha", name: "Alpha Mac")
        let beta = machine(id: "beta", name: "Beta Mac")
        let sources = [
            FirstMateFleetSource(
                machine: alpha,
                configuration: configuration(for: alpha, token: "alpha-token"),
                client: SyntheticScriptedFleetClient(script: alphaScript)
            ),
            FirstMateFleetSource(
                machine: beta,
                configuration: configuration(for: beta, token: "beta-token"),
                client: SyntheticScriptedFleetClient(script: betaScript)
            ),
            source(id: "legacy", name: "Legacy Mac", token: "legacy-token", result: .failure(.server(status: 501, message: "Unsupported"))),
        ]
        let lifecycle = index.activate(sources: sources, connectionGeneration: 8)
        await index.refresh(lifecycle: lifecycle)
        #expect(index.attentionCount == 2)

        await index.refresh(lifecycle: lifecycle)
        #expect(index.attentionCount == 1)
        let failedAlpha = try #require(index.hosts.first(where: { $0.id == "alpha" }))
        #expect(failedAlpha.features.map(\.id) == ["alpha-direction"])
        #expect(failedAlpha.lastUpdated != nil)
        #expect(failedAlpha.error != nil)
        #expect(!failedAlpha.unsupported)
        #expect(index.hosts.first(where: { $0.id == "beta" })?.features.map(\.id) == ["beta-working"])

        await index.refresh(lifecycle: lifecycle)
        #expect(index.attentionCount == 0)
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.features.isEmpty == true)
        #expect(index.hosts.first(where: { $0.id == "legacy" })?.unsupported == true)
    }

    @Test("Rotated and removed connections drop obsolete attention")
    func rotationAndRemovalDropAttention() async throws {
        let index = FirstMateFleetIndex()
        let alpha = machine(id: "alpha", name: "Alpha Mac")
        let beta = machine(id: "beta", name: "Beta Mac")
        let awaiting = feature(id: "waiting", status: "awaiting_direction")
        let blocked = feature(id: "blocked", status: "blocked")
        let oldAlpha = FirstMateFleetSource(
            machine: alpha,
            configuration: configuration(for: alpha, token: "old-token"),
            client: SyntheticFleetClient { .init(ok: true, features: [awaiting]) }
        )
        let betaSource = FirstMateFleetSource(
            machine: beta,
            configuration: configuration(for: beta, token: "beta-token"),
            client: SyntheticFleetClient { .init(ok: true, features: [blocked]) }
        )

        let firstLifecycle = index.activate(sources: [oldAlpha, betaSource], connectionGeneration: 6)
        await index.refresh(lifecycle: firstLifecycle)
        #expect(index.attentionCount == 2)

        let rotatedAlpha = FirstMateFleetSource(
            machine: alpha,
            configuration: configuration(for: alpha, token: "rotated-token"),
            client: SyntheticFleetClient { .init(ok: true, features: []) }
        )
        let secondLifecycle = index.activate(sources: [rotatedAlpha, betaSource], connectionGeneration: 6)
        // Alpha's rotated credential clears its own contribution immediately,
        // while Beta's unchanged connection keeps its cached reminder.
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.features.isEmpty == true)
        #expect(index.hosts.first(where: { $0.id == "beta" })?.features.map(\.id) == ["blocked"])
        #expect(index.attentionCount == 1)
        await index.refresh(lifecycle: secondLifecycle)
        #expect(index.attentionCount == 1)

        let thirdLifecycle = index.activate(sources: [rotatedAlpha], connectionGeneration: 6)
        #expect(index.attentionCount == 0)
        await index.refresh(lifecycle: thirdLifecycle)
        #expect(index.attentionCount == 0)
        #expect(index.hosts.map(\.machineID) == ["alpha"])
    }

    @Test("Unchanged offline hosts keep outstanding attention across reorder and unrelated edits")
    func unchangedOfflineHostRetainsAttentionAcrossRosterEdits() async throws {
        let index = FirstMateFleetIndex()
        let alpha = machine(id: "alpha", name: "Alpha Mac")
        let beta = machine(id: "beta", name: "Beta Mac")
        let alphaConfiguration = configuration(for: alpha, token: "alpha-token")
        let betaConfiguration = configuration(for: beta, token: "beta-token")

        // Alpha reports attention once and then goes offline. A failed refresh
        // keeps the last successful list instead of implying resolution.
        let alphaScript = FirstMateFleetResponseScript([
            .success([feature(id: "alpha-waiting", status: "awaiting_direction")]),
            .failure(.server(status: 500, message: "Temporarily unavailable")),
        ])
        let betaScript = FirstMateFleetResponseScript([
            .success([feature(id: "beta-working", status: "running")]),
        ])
        let initial = [
            FirstMateFleetSource(
                machine: alpha,
                configuration: alphaConfiguration,
                client: SyntheticScriptedFleetClient(script: alphaScript)
            ),
            FirstMateFleetSource(
                machine: beta,
                configuration: betaConfiguration,
                client: SyntheticScriptedFleetClient(script: betaScript)
            ),
        ]
        let initialLifecycle = index.activate(sources: initial, connectionGeneration: 30)
        await index.refresh(lifecycle: initialLifecycle)
        #expect(index.attentionCount == 1)
        await index.refresh(lifecycle: initialLifecycle)
        let offlineAlpha = try #require(index.hosts.first(where: { $0.id == "alpha" }))
        #expect(offlineAlpha.error != nil)
        #expect(offlineAlpha.lastUpdated != nil)
        #expect(offlineAlpha.features.map(\.id) == ["alpha-waiting"])
        #expect(index.attentionCount == 1)

        // Reordering the roster is not a connection change.
        let reordered = [
            FirstMateFleetSource(
                machine: beta,
                configuration: betaConfiguration,
                client: SyntheticScriptedFleetClient(script: betaScript)
            ),
            FirstMateFleetSource(
                machine: alpha,
                configuration: alphaConfiguration,
                client: SyntheticScriptedFleetClient(script: alphaScript)
            ),
        ]
        let reorderLifecycle = index.activate(sources: reordered, connectionGeneration: 30)
        #expect(index.hosts.map(\.machineID) == ["beta", "alpha"])
        #expect(index.attentionCount == 1)
        await index.refresh(lifecycle: reorderLifecycle)
        #expect(index.attentionCount == 1)
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.features.map(\.id) == ["alpha-waiting"])

        // Editing another host bumps the process-wide generation, but Alpha's
        // authenticated connection is unchanged, so its reminder stays.
        // Renaming Alpha updates the label without discarding the cache either.
        let renamedAlpha = HerdrMachine(id: alpha.id, name: "Alpha Mac Renamed", urlString: alpha.urlString)
        let edited = [
            FirstMateFleetSource(
                machine: renamedAlpha,
                configuration: alphaConfiguration,
                client: SyntheticScriptedFleetClient(script: alphaScript)
            ),
            FirstMateFleetSource(
                machine: beta,
                configuration: configuration(for: beta, token: "rotated-beta-token"),
                client: SyntheticScriptedFleetClient(script: betaScript)
            ),
        ]
        let editedLifecycle = index.activate(sources: edited, connectionGeneration: 31)
        let renamedOfflineAlpha = try #require(index.hosts.first(where: { $0.id == "alpha" }))
        #expect(renamedOfflineAlpha.machineName == "Alpha Mac Renamed")
        #expect(renamedOfflineAlpha.features.map(\.id) == ["alpha-waiting"])
        #expect(index.attentionCount == 1)
        await index.refresh(lifecycle: editedLifecycle)
        #expect(index.attentionCount == 1)
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.error != nil)

        // Removing the offline host clears its contribution immediately, and
        // no later refresh can restore it.
        let removedLifecycle = index.activate(sources: [edited[1]], connectionGeneration: 31)
        #expect(index.hosts.map(\.machineID) == ["beta"])
        #expect(index.attentionCount == 0)
        await index.refresh(lifecycle: removedLifecycle)
        #expect(index.attentionCount == 0)
    }

    @Test("Reconfiguring one host clears only that host's cached attention")
    func reconfiguredHostClearsOnlyItself() async throws {
        let index = FirstMateFleetIndex()
        let alpha = machine(id: "alpha", name: "Alpha Mac")
        let beta = machine(id: "beta", name: "Beta Mac")
        let alphaConfiguration = configuration(for: alpha, token: "alpha-token")
        let betaConfiguration = configuration(for: beta, token: "beta-token")
        let betaWaiting = feature(id: "beta-waiting", status: "blocked")

        let initial = [
            FirstMateFleetSource(
                machine: alpha,
                configuration: alphaConfiguration,
                client: SyntheticScriptedFleetClient(script: FirstMateFleetResponseScript([
                    .success([feature(id: "alpha-waiting", status: "awaiting_direction")]),
                    .failure(.server(status: 500, message: "Temporarily unavailable")),
                ]))
            ),
            FirstMateFleetSource(
                machine: beta,
                configuration: betaConfiguration,
                client: SyntheticScriptedFleetClient(script: FirstMateFleetResponseScript([.success([betaWaiting])]))
            ),
        ]
        let initialLifecycle = index.activate(sources: initial, connectionGeneration: 40)
        await index.refresh(lifecycle: initialLifecycle)
        await index.refresh(lifecycle: initialLifecycle)
        #expect(index.attentionCount == 2)

        // Rotating Beta clears Beta only; Alpha's offline reminder survives.
        let rotatedBeta = FirstMateFleetSource(
            machine: beta,
            configuration: configuration(for: beta, token: "rotated-beta-token"),
            client: SyntheticScriptedFleetClient(script: FirstMateFleetResponseScript([
                .success([feature(id: "beta-working", status: "running")]),
            ]))
        )
        let secondLifecycle = index.activate(sources: [initial[0], rotatedBeta], connectionGeneration: 41)
        #expect(index.hosts.first(where: { $0.id == "beta" })?.features.isEmpty == true)
        #expect(index.hosts.first(where: { $0.id == "alpha" })?.features.map(\.id) == ["alpha-waiting"])
        #expect(index.attentionCount == 1)
        await index.refresh(lifecycle: secondLifecycle)
        #expect(index.attentionCount == 1)
    }

    @Test("A delayed response from a rotated connection cannot restore attention")
    func delayedRotatedResponseRejected() async throws {
        let gate = FirstMateFleetResponseGate()
        let machine = machine(id: "alpha", name: "Alpha Mac")
        let index = FirstMateFleetIndex()
        let oldSource = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "old-token"),
            client: SyntheticFleetClient { try await gate.fetch() }
        )
        let oldLifecycle = index.activate(sources: [oldSource], connectionGeneration: 4)
        let oldRefresh = Task { await index.refresh(lifecycle: oldLifecycle) }
        defer {
            oldRefresh.cancel()
            Task { await gate.cancelPending() }
        }
        try await gate.waitForRequest()

        let rotatedSource = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "rotated-token"),
            client: SyntheticFleetClient { .init(ok: true, features: []) }
        )
        let rotatedLifecycle = index.activate(sources: [rotatedSource], connectionGeneration: 4)
        await index.refresh(lifecycle: rotatedLifecycle)
        #expect(index.attentionCount == 0)

        await gate.succeed(with: [feature(id: "stale", status: "awaiting_direction")])
        await oldRefresh.value
        #expect(index.attentionCount == 0)
        #expect(index.hosts.first?.features.isEmpty == true)
    }

    @Test("Cancelling observation stops polling and releases loading state")
    func cancelledObservationStopsPolling() async throws {
        let gate = FirstMateFleetStepGate()
        let machine = machine(id: "alpha", name: "Alpha Mac")
        let index = FirstMateFleetIndex()
        index.pollingInterval = .milliseconds(5)
        let source = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "alpha-token"),
            client: SyntheticFleetClient { try await gate.fetch() }
        )
        let observation = Task { await index.observe(sources: [source], connectionGeneration: 13) }
        try await gate.waitForFetch()
        #expect(index.hosts.first?.isLoading == true)

        observation.cancel()
        await gate.cancelPending()
        await observation.value

        #expect(await gate.fetchCount == 1)
        #expect(index.hosts.first?.isLoading == false)
        #expect(index.attentionCount == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.fetchCount == 1)
    }

    @Test("A superseded observer cannot clear or overwrite a newer roster")
    func supersededObserverDoesNotClobber() async throws {
        let staleGate = FirstMateFleetStepGate()
        let staleMachine = machine(id: "alpha", name: "Alpha Mac")
        let freshMachine = machine(id: "beta", name: "Beta Mac")
        let index = FirstMateFleetIndex()
        index.pollingInterval = .milliseconds(5)

        let staleSource = FirstMateFleetSource(
            machine: staleMachine,
            configuration: configuration(for: staleMachine, token: "alpha-token"),
            client: SyntheticFleetClient { try await staleGate.fetch() }
        )
        let staleObservation = Task { await index.observe(sources: [staleSource], connectionGeneration: 1) }
        defer {
            staleObservation.cancel()
            Task { await staleGate.cancelPending() }
        }
        try await staleGate.waitForFetch()
        await staleGate.supply(.init(ok: true, features: [feature(id: "stale-waiting", status: "awaiting_direction")]))
        try await waitForFleetIndexCondition("stale attention") { index.attentionCount == 1 }

        let freshScript = FirstMateFleetResponseScript([
            .success([feature(id: "fresh-working", status: "running")]),
            .success([feature(id: "fresh-blocked", status: "blocked")]),
        ])
        let freshSource = FirstMateFleetSource(
            machine: freshMachine,
            configuration: configuration(for: freshMachine, token: "beta-token"),
            client: SyntheticScriptedFleetClient(script: freshScript)
        )
        let freshLifecycle = index.activate(sources: [freshSource], connectionGeneration: 2)
        await index.refresh(lifecycle: freshLifecycle)
        #expect(index.attentionCount == 0)
        #expect(index.hosts.map(\.machineID) == ["beta"])

        staleObservation.cancel()
        await staleGate.cancelPending()
        await staleObservation.value
        #expect(index.attentionCount == 0)
        #expect(index.hosts.map(\.machineID) == ["beta"])

        await index.refresh(lifecycle: freshLifecycle)
        #expect(index.attentionCount == 1)
        #expect(index.hosts.first?.features.map(\.id) == ["fresh-blocked"])
    }

    @Test("An empty roster resets obsolete hosts and exits without polling")
    func emptyRosterResetsAndExits() async throws {
        let index = FirstMateFleetIndex()
        let script = FirstMateFleetResponseScript([.success([feature(id: "waiting", status: "awaiting_direction")])])
        let machine = machine(id: "alpha", name: "Alpha Mac")
        let source = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "alpha-token"),
            client: SyntheticScriptedFleetClient(script: script)
        )
        let lifecycle = index.activate(sources: [source], connectionGeneration: 3)
        await index.refresh(lifecycle: lifecycle)
        #expect(index.attentionCount == 1)

        index.pollingInterval = .milliseconds(5)
        await index.observe(sources: [], connectionGeneration: 3)
        #expect(index.hosts.isEmpty)
        #expect(index.attentionCount == 0)
        #expect(await script.fetchCount == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await script.fetchCount == 1)
    }

    @Test("An unchanged poll publishes nothing, so the Dashboard is not re-rendered every interval")
    func unchangedPollIsQuiet() async {
        let index = FirstMateFleetIndex()
        let features = [feature(id: "waiting", status: "awaiting_direction")]
        let machine = machine(id: "alpha", name: "Alpha Mac")
        let source = FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: "alpha-token"),
            client: SyntheticFleetClient { .init(ok: true, features: features) }
        )
        let lifecycle = index.activate(sources: [source], connectionGeneration: 5)
        await index.refresh(lifecycle: lifecycle)
        let revision = index.contentRevision
        #expect(index.hosts.first?.lastUpdated != nil)

        let changed = FleetChangeFlag()
        withObservationTracking {
            _ = index.hosts
            _ = index.contentRevision
        } onChange: { changed.set() }
        await index.refresh(lifecycle: lifecycle)
        await index.refresh(lifecycle: lifecycle)
        #expect(!changed.value)
        #expect(index.contentRevision == revision)
        #expect(index.hosts.first?.isLoading == false)
    }

    private func machine(id: String, name: String) -> HerdrMachine {
        HerdrMachine(id: id, name: name, urlString: "https://\(id).example.invalid")
    }

    private func configuration(for machine: HerdrMachine, token: String) -> ServerConfiguration {
        ServerConfiguration(urlString: machine.urlString, token: token)!
    }

    private func source(
        id: String,
        name: String,
        token: String,
        result: Result<[FirstMateFeature], APIError>
    ) -> FirstMateFleetSource {
        let machine = machine(id: id, name: name)
        return FirstMateFleetSource(
            machine: machine,
            configuration: configuration(for: machine, token: token),
            client: SyntheticFleetClient {
                switch result {
                case .success(let features): return .init(ok: true, features: features)
                case .failure(let error): throw error
                }
            }
        )
    }

    private func snapshot(id: String, title: String, goal: String) -> FirstMateSnapshot {
        FirstMateDemo.newFeature(title: title, goal: goal, cwd: "/tmp/synthetic", id: id)
    }

    private func feature(id: String, status: String) -> FirstMateFeature {
        var feature = snapshot(id: id, title: "Synthetic feature \(id)", goal: "A synthetic goal for \(id)").feature
        feature.status = status
        return feature
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "FirstMateFleetIndexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private final class SyntheticFleetClient: FirstMateClient, @unchecked Sendable {
    private let list: @Sendable () async throws -> FirstMateFeatureList
    private let snapshot: FirstMateSnapshot?

    init(
        snapshot: FirstMateSnapshot? = nil,
        list: @escaping @Sendable () async throws -> FirstMateFeatureList
    ) {
        self.snapshot = snapshot
        self.list = list
    }

    convenience init(snapshot: FirstMateSnapshot) {
        self.init(snapshot: snapshot) { .init(ok: true, features: [snapshot.feature]) }
    }

    convenience init(list: @escaping @Sendable () async throws -> FirstMateFeatureList) {
        self.init(snapshot: nil, list: list)
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await list() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let snapshot, snapshot.feature.id == id else { throw APIError.invalidResponse }
        return snapshot
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        guard let snapshot else { throw APIError.invalidResponse }
        return snapshot
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}

private actor FirstMateFleetResponseGate {
    private var response: CheckedContinuation<FirstMateFeatureList, any Error>?

    func fetch() async throws -> FirstMateFeatureList {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    response = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    func waitForRequest() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while response == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw FirstMateFleetGateError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func succeed(with features: [FirstMateFeature]) {
        response?.resume(returning: .init(ok: true, features: features))
        response = nil
    }

    func cancelPending() {
        response?.resume(throwing: CancellationError())
        response = nil
    }
}

private enum FirstMateFleetGateError: Error {
    case requestTimedOut
}

/// A fleet observer wait that fails instead of hanging when a condition is not
/// met before its deadline.
@MainActor
private func waitForFleetIndexCondition(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw FirstMateFleetWaitError.timedOut(description)
        }
        try await clock.sleep(for: .milliseconds(2))
    }
}

private enum FirstMateFleetWaitError: Error {
    case timedOut(String)
}

/// A per-fetch gate that lets a test hold each polling response until the
/// corresponding assertion has observed the previous state.
private actor FirstMateFleetStepGate {
    private var queued: [FirstMateFeatureList] = []
    private var waiting: CheckedContinuation<FirstMateFeatureList, any Error>?
    private var fetches = 0

    var fetchCount: Int { fetches }

    func fetch() async throws -> FirstMateFeatureList {
        fetches += 1
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if queued.isEmpty {
                    waiting = continuation
                } else {
                    continuation.resume(returning: queued.removeFirst())
                }
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    func waitForFetch(_ count: Int = 1) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while fetches < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw FirstMateFleetWaitError.timedOut("fleet gate did not receive \(count) fetch(es)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func supply(_ response: FirstMateFeatureList) {
        if let waiting {
            waiting.resume(returning: response)
            self.waiting = nil
        } else {
            queued.append(response)
        }
    }

    func cancelPending() {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

/// A deterministic list of fetch outcomes for tests that drive refreshes
/// manually. Once the script is exhausted it repeats its last outcome.
private actor FirstMateFleetResponseScript {
    private var pending: [Result<[FirstMateFeature], APIError>]
    private var last: Result<[FirstMateFeature], APIError>?
    private var fetches = 0

    init(_ responses: [Result<[FirstMateFeature], APIError>]) {
        pending = responses
    }

    var fetchCount: Int { fetches }

    func next() throws -> FirstMateFeatureList {
        fetches += 1
        let response: Result<[FirstMateFeature], APIError>
        if pending.isEmpty {
            guard let last else { throw APIError.invalidResponse }
            response = last
        } else {
            response = pending.removeFirst()
            last = response
        }
        switch response {
        case .success(let features):
            return FirstMateFeatureList(ok: true, features: features)
        case .failure(let error):
            throw error
        }
    }
}

private final class SyntheticScriptedFleetClient: FirstMateClient, @unchecked Sendable {
    private let script: FirstMateFleetResponseScript

    init(script: FirstMateFleetResponseScript) {
        self.script = script
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await script.next() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}

/// Observation's change callback is not main-actor isolated.
private final class FleetChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
