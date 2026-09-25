import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("First Mate mobile fleet", .serialized)
@MainActor
struct FirstMateMobileFleetTests {
    // MARK: - Scope preference

    @Test("Legacy-only, missing, and invalid scope preferences open on All Machines")
    func scopePreferenceDefaults() {
        let defaults = isolatedDefaults()
        defaults.set("host-legacy", forKey: FirstMateScopePreference.legacyMachineKey)
        let preference = FirstMateScopePreference(defaults: defaults)

        #expect(preference.load() == .all)
        // The legacy key is preserved untouched.
        #expect(defaults.string(forKey: FirstMateScopePreference.legacyMachineKey) == "host-legacy")

        for invalid in ["host-legacy", "all", "v2:all", "v1:machine:", "v1:", "machine:host", ""] {
            defaults.set(invalid, forKey: FirstMateScopePreference.key)
            #expect(preference.load() == .all, "\(invalid) must not decode to a machine")
        }
        defaults.removeObject(forKey: FirstMateScopePreference.key)
        #expect(preference.load() == .all)

        preference.save(.machine("host-a"))
        #expect(preference.load() == .machine("host-a"))
        #expect(defaults.string(forKey: FirstMateScopePreference.legacyMachineKey) == "host-legacy")
        preference.save(.all)
        #expect(preference.load() == .all)
    }

    @Test("Tagged scope encoding never collides with a real machine ID")
    func taggedScopeEncoding() {
        #expect(FirstMateScopePreference.encode(.all) == "v1:all")
        #expect(FirstMateScopePreference.encode(.machine("all")) == "v1:machine:all")
        #expect(FirstMateScopePreference.encode(.machine("v1:all")) == "v1:machine:v1:all")

        #expect(FirstMateScopePreference.decode("v1:all") == .all)
        #expect(FirstMateScopePreference.decode("v1:machine:all") == .machine("all"))
        #expect(FirstMateScopePreference.decode("v1:machine:v1:all") == .machine("v1:all"))
        #expect(FirstMateScopePreference.decode("v1:machine:") == nil)
        #expect(FirstMateScopePreference.decode("v2:all") == nil)
        #expect(FirstMateScopePreference.decode("garbage") == nil)
        #expect(FirstMateScopePreference.decode(nil) == nil)
    }

    @Test("Scope resolution falls back to All Machines for absent and removed hosts")
    func scopeResolution() {
        #expect(FirstMateMachineScope.resolved(nil, availableMachineIDs: ["a"]) == .all)
        #expect(FirstMateMachineScope.resolved(.all, availableMachineIDs: []) == .all)
        #expect(FirstMateMachineScope.resolved(.machine("a"), availableMachineIDs: ["a", "b"]) == .machine("a"))
        #expect(FirstMateMachineScope.resolved(.machine("gone"), availableMachineIDs: ["a", "b"]) == .all)
        #expect(FirstMateMachineScope.all.includes(machineID: "anything"))
        #expect(!FirstMateMachineScope.machine("a").includes(machineID: "b"))
    }

    @Test("Explicit fleet scope choices survive relaunch while a legacy-only install stays on All Machines")
    func explicitScopePersistence() {
        let defaults = isolatedDefaults()
        defaults.set("host-a", forKey: FirstMateScopePreference.legacyMachineKey)

        var fleet = FirstMateMobileFleetStore(defaults: defaults)
        #expect(fleet.scope == .all)

        fleet.selectScope(.machine("host-a"))
        fleet = FirstMateMobileFleetStore(defaults: defaults)
        #expect(fleet.scope == .machine("host-a"))

        fleet.selectScope(.all)
        fleet = FirstMateMobileFleetStore(defaults: defaults)
        #expect(fleet.scope == .all)
        #expect(defaults.string(forKey: FirstMateScopePreference.legacyMachineKey) == "host-a")
    }

    // MARK: - Aggregation and identity

    @Test("Zero, one, and multiple hosts aggregate under All Machines with distinct composite identities")
    func aggregationAndDuplicateIdentity() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let emptyLifecycle = fleet.activate(sources: [], connectionGeneration: 1)
        #expect(emptyLifecycle > 0)
        #expect(fleet.hosts.isEmpty)
        #expect(fleet.visibleRows.isEmpty)
        #expect(fleet.attentionCount == 0)
        #expect(fleet.resolvedScope == .all)

        // Two machines share a display name and a feature ID.
        let alpha = machine("alpha", "Shared Mac")
        let beta = machine("beta", "Shared Mac")
        let alphaFeature = feature(id: "shared", title: "Alpha cleanup", status: "awaiting_direction")
        let betaFeature = feature(id: "shared", title: "Beta cleanup", status: "blocked")
        let lifecycle = fleet.activate(sources: [
            source(alpha, active: [alphaFeature]),
            source(beta, active: [betaFeature]),
        ], connectionGeneration: 2)
        await fleet.refresh(lifecycle: lifecycle)

        #expect(fleet.hosts.count == 2)
        #expect(fleet.visibleRows.count == 2)
        #expect(Set(fleet.visibleRows.map(\.target)).count == 2)
        #expect(fleet.visibleRows.allSatisfy { $0.machineName == "Shared Mac" })
        #expect(fleet.feature(for: FirstMateFeatureTarget(machineID: "alpha", featureID: "shared"))?.title == "Alpha cleanup")
        #expect(fleet.feature(for: FirstMateFeatureTarget(machineID: "beta", featureID: "shared"))?.title == "Beta cleanup")
        #expect(fleet.attentionCount == 2)

        // A single configured machine still offers All Machines.
        let single = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let singleLifecycle = single.activate(sources: [source(alpha, active: [alphaFeature])], connectionGeneration: 3)
        await single.refresh(lifecycle: singleLifecycle)
        #expect(single.resolvedScope == .all)
        #expect(single.visibleRows.count == 1)
        #expect(single.hosts.first?.hasLoaded == true)
        #expect(single.hosts.first?.isEmpty == false)
    }

    @Test("A selected host that leaves the roster falls back to All Machines, not another host")
    func removedHostFallsBackToAll() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let firstLifecycle = fleet.activate(sources: [
            source(alpha, active: [feature(id: "alpha", title: "Alpha")]),
            source(beta, active: [feature(id: "beta", title: "Beta")]),
        ], connectionGeneration: 1)
        await fleet.refresh(lifecycle: firstLifecycle)

        fleet.selectScope(.machine("alpha"))
        #expect(fleet.resolvedScope == .machine("alpha"))
        #expect(fleet.visibleRows.map(\.machineID) == ["alpha"])

        let secondLifecycle = fleet.activate(sources: [
            source(beta, active: [feature(id: "beta", title: "Beta")]),
        ], connectionGeneration: 1)
        #expect(fleet.scope == .machine("alpha"))
        #expect(fleet.resolvedScope == .all)
        #expect(fleet.visibleHosts.map(\.machineID) == ["beta"])
        await fleet.refresh(lifecycle: secondLifecycle)
        #expect(fleet.visibleRows.map(\.machineID) == ["beta"])
    }

    @Test("Search and Show Archived apply consistently across visible hosts")
    func searchAndArchivedAcrossHosts() async throws {
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let activeAlpha = feature(id: "alpha-active", title: "Alpha migration", status: "running")
        let archivedAlpha = feature(id: "alpha-archived", title: "Alpha cleanup", status: "done", archived: true)
        let activeBeta = feature(id: "beta-active", title: "Beta migration", status: "running")
        let archivedBeta = feature(id: "beta-archived", title: "Beta cleanup", status: "done", archived: true)

        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let lifecycle = fleet.activate(sources: [
            source(alpha, active: [activeAlpha], archived: [archivedAlpha]),
            source(beta, active: [activeBeta], archived: [archivedBeta]),
        ], connectionGeneration: 4)
        await fleet.refresh(lifecycle: lifecycle)

        #expect(fleet.visibleRows.map(\.featureID) == ["alpha-active", "beta-active"])
        #expect(fleet.waitingRows.isEmpty)
        #expect(fleet.otherActiveRows.map(\.featureID) == ["alpha-active", "beta-active"])

        fleet.search = "cleanup"
        #expect(fleet.visibleRows.isEmpty)

        fleet.search = ""
        fleet.setShowArchived(true)
        await fleet.refresh(lifecycle: lifecycle)
        #expect(fleet.visibleRows.map(\.featureID) == ["alpha-active", "alpha-archived", "beta-active", "beta-archived"])
        #expect(fleet.archivedRows.map(\.featureID) == ["alpha-archived", "beta-archived"])
        #expect(fleet.visibleRows.count(where: { $0.machineID == "alpha" }) == 2)

        // A machine-name match surfaces every row of that host.
        fleet.search = "beta"
        #expect(fleet.visibleRows.map(\.featureID) == ["beta-active", "beta-archived"])

        fleet.setShowArchived(false)
        #expect(fleet.visibleRows.map(\.featureID) == ["beta-active"])
    }

    @Test("Hosts fail independently and expose loading, empty, stale, and unsupported state")
    func independentHostState() async throws {
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let gamma = machine("gamma", "Gamma Mac")
        let delta = machine("delta", "Delta Mac")

        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let lifecycle = fleet.activate(sources: [
            source(alpha, active: [feature(id: "alpha", title: "Alpha")]),
            source(beta),
            FirstMateMobileFleetSource(
                machine: gamma,
                configuration: configuration(gamma, "gamma-token"),
                client: SyntheticMobileFleetClient(error: .server(status: 500, message: "Unavailable"))
            ),
            FirstMateMobileFleetSource(
                machine: delta,
                configuration: configuration(delta, "delta-token"),
                client: SyntheticMobileFleetClient(error: .server(status: 404, message: "Missing"))
            ),
        ], connectionGeneration: 5)
        await fleet.refresh(lifecycle: lifecycle)

        let alphaHost = try #require(fleet.host(for: FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha")))
        #expect(alphaHost.hasLoaded)
        #expect(alphaHost.error == nil)
        #expect(!alphaHost.isStale)

        let betaHost = try #require(fleet.hosts.first(where: { $0.machineID == "beta" }))
        #expect(betaHost.isEmpty)
        #expect(betaHost.error == nil)

        let gammaHost = try #require(fleet.hosts.first(where: { $0.machineID == "gamma" }))
        #expect(gammaHost.hasLoaded)
        #expect(gammaHost.error != nil)
        #expect(gammaHost.features.isEmpty)
        #expect(gammaHost.isUnavailable)
        #expect(!gammaHost.isFirstMateUnsupported)

        let deltaHost = try #require(fleet.hosts.first(where: { $0.machineID == "delta" }))
        #expect(deltaHost.isFirstMateUnsupported)
        #expect(!deltaHost.isUnavailable)

        // Healthy hosts keep flowing while a peer is offline.
        #expect(fleet.visibleRows.map(\.machineID) == ["alpha"])
    }

    @Test("Cached features survive a host outage and mark the host stale")
    func staleHostRetainsFeatures() async throws {
        let alpha = machine("alpha", "Alpha Mac")
        let alphaFeature = feature(id: "alpha", title: "Alpha", status: "awaiting_direction")
        let script = MobileFleetFeatureScript([
            .success([alphaFeature]),
            .failure(.server(status: 500, message: "Temporarily unavailable")),
        ])
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let lifecycle = fleet.activate(sources: [
            FirstMateMobileFleetSource(
                machine: alpha,
                configuration: configuration(alpha, "alpha-token"),
                client: SyntheticMobileFleetClient(
                    list: { _ in try await script.next() },
                    snapshot: { id in
                        guard id == alphaFeature.id else { throw APIError.invalidResponse }
                        return FirstMateSnapshot(feature: alphaFeature)
                    }
                )
            ),
        ], connectionGeneration: 6)
        await fleet.refresh(lifecycle: lifecycle)
        let firstSeen = try #require(fleet.hosts.first?.lastUpdated)
        #expect(fleet.hosts.first?.features.map(\.id) == ["alpha"])
        #expect(fleet.hosts.first?.error == nil)

        await fleet.refresh(lifecycle: lifecycle)
        let host = try #require(fleet.hosts.first)
        #expect(host.isStale)
        #expect(!host.isUnavailable)
        #expect(host.features.map(\.id) == ["alpha"])
        #expect(host.lastUpdated == firstSeen)
        #expect(fleet.attentionCount == 1)
    }

    // MARK: - Host isolation

    @Test("Roster reordering keeps each host store and its draft")
    func rosterReorderPreservesStores() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let firstLifecycle = fleet.activate(sources: [
            source(alpha, active: [feature(id: "alpha-feature", title: "Alpha feature")]),
            source(beta, active: [feature(id: "beta-feature", title: "Beta feature")]),
        ], connectionGeneration: 7)
        await fleet.refresh(lifecycle: firstLifecycle)

        let alphaStore = try #require(fleet.store(forMachineID: "alpha"))
        let betaStore = try #require(fleet.store(forMachineID: "beta"))
        #expect(fleet.open(FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha-feature")))
        alphaStore.draft = "alpha draft"

        let secondLifecycle = fleet.activate(sources: [
            source(beta, active: [feature(id: "beta-feature", title: "Beta feature")]),
            source(alpha, active: [feature(id: "alpha-feature", title: "Alpha feature")]),
        ], connectionGeneration: 7)
        #expect(fleet.store(forMachineID: "alpha") === alphaStore)
        #expect(fleet.store(forMachineID: "beta") === betaStore)
        #expect(alphaStore.draft == "alpha draft")
        #expect(fleet.selectedTarget == FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha-feature"))
        #expect(fleet.hosts.map(\.machineID) == ["beta", "alpha"])

        await fleet.refresh(lifecycle: secondLifecycle)
        #expect(fleet.visibleRows.map(\.machineID) == ["beta", "alpha"])
        #expect(alphaStore.draft == "alpha draft")
    }

    @Test("Rotating one host's connection retires only that store and rejects delayed work")
    func connectionRotationIsolatesHost() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let gate = MobileFleetGate()
        let firstLifecycle = fleet.activate(sources: [
            FirstMateMobileFleetSource(
                machine: alpha,
                configuration: configuration(alpha, "alpha-token"),
                client: SyntheticMobileFleetClient(list: { _ in try await gate.fetch().features })
            ),
            source(beta, active: [feature(id: "beta-feature", title: "Beta feature")]),
        ], connectionGeneration: 8)

        let oldRefresh = Task { await fleet.refresh(lifecycle: firstLifecycle) }
        try await gate.waitForRequest()
        let oldAlphaStore = try #require(fleet.store(forMachineID: "alpha"))
        oldAlphaStore.receive(FirstMateSnapshot(feature: feature(id: "alpha-feature", title: "Alpha feature")))
        #expect(fleet.open(FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha-feature")))
        oldAlphaStore.draft = "alpha draft"
        let oldContext = oldAlphaStore.operationContext
        let betaStore = try #require(fleet.store(forMachineID: "beta"))

        let rotated = machine("alpha", "Alpha Mac")
        let secondLifecycle = fleet.activate(sources: [
            FirstMateMobileFleetSource(
                machine: rotated,
                configuration: configuration(rotated, "rotated-alpha-token"),
                client: SyntheticMobileFleetClient(snapshots: [FirstMateSnapshot(feature: feature(id: "alpha-feature", title: "Alpha feature"))])
            ),
            source(beta, active: [feature(id: "beta-feature", title: "Beta feature")]),
        ], connectionGeneration: 8)

        #expect(fleet.store(forMachineID: "alpha") !== oldAlphaStore)
        #expect(fleet.store(forMachineID: "beta") === betaStore)
        // The conversation is fenced with the host it belonged to.
        #expect(fleet.selectedTarget == nil)
        #expect(oldAlphaStore.features.isEmpty)
        #expect(oldAlphaStore.draft.isEmpty)
        #expect(!(await oldAlphaStore.create(
            title: "Delayed create",
            goal: "Must never reach the replacement host",
            cwd: "/tmp/synthetic",
            requestID: "delayed-create",
            expectedContext: oldContext
        )))

        await gate.succeed(.init(ok: true, features: [feature(id: "stale", title: "Stale")]))
        await oldRefresh.value
        #expect(fleet.hosts.first(where: { $0.machineID == "alpha" })?.features.isEmpty == true)

        await fleet.refresh(lifecycle: secondLifecycle)
        #expect(fleet.store(forMachineID: "alpha")?.features.map(\.id) == ["alpha-feature"])
        #expect(fleet.hosts.first(where: { $0.machineID == "beta" })?.features.map(\.id) == ["beta-feature"])
    }

    @Test("A removed host's delayed response cannot reappear")
    func removedHostDelayedResponse() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let gate = MobileFleetGate()
        let firstLifecycle = fleet.activate(sources: [
            FirstMateMobileFleetSource(
                machine: alpha,
                configuration: configuration(alpha, "alpha-token"),
                client: SyntheticMobileFleetClient(list: { _ in try await gate.fetch().features })
            ),
            source(beta, active: [feature(id: "beta", title: "Beta")]),
        ], connectionGeneration: 9)
        let refresh = Task { await fleet.refresh(lifecycle: firstLifecycle) }
        try await gate.waitForRequest()
        let removedStore = try #require(fleet.store(forMachineID: "alpha"))

        let secondLifecycle = fleet.activate(sources: [
            source(beta, active: [feature(id: "beta", title: "Beta")]),
        ], connectionGeneration: 9)
        #expect(fleet.hosts.map(\.machineID) == ["beta"])
        #expect(fleet.store(forMachineID: "alpha") == nil)

        await gate.succeed(.init(ok: true, features: [feature(id: "stale", title: "Stale")]))
        await refresh.value
        #expect(removedStore.features.isEmpty)

        await fleet.refresh(lifecycle: secondLifecycle)
        #expect(fleet.hosts.map(\.machineID) == ["beta"])
        #expect(fleet.hosts.first?.features.map(\.id) == ["beta"])
    }

    @Test("Feature targets route to the exact owning store without changing the browsing scope")
    func exactOwnerRouting() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let lifecycle = fleet.activate(sources: [
            source(alpha, active: [feature(id: "shared", title: "Alpha shared")]),
            source(beta, active: [feature(id: "shared", title: "Beta shared")]),
        ], connectionGeneration: 10)

        let alphaStore = try #require(fleet.store(forMachineID: "alpha"))
        let betaStore = try #require(fleet.store(forMachineID: "beta"))
        let alphaTarget = FirstMateFeatureTarget(machineID: "alpha", featureID: "shared")
        let betaTarget = FirstMateFeatureTarget(machineID: "beta", featureID: "shared")
        #expect(fleet.store(for: alphaTarget) === alphaStore)
        #expect(fleet.store(for: betaTarget) === betaStore)
        #expect(alphaStore.selectedFeatureID == nil)
        #expect(betaStore.selectedFeatureID == nil)

        // Opening a feature selects it only in the store that owns the machine.
        #expect(fleet.open(alphaTarget))
        #expect(alphaStore.selectedFeatureID == "shared")
        #expect(betaStore.selectedFeatureID == nil)
        #expect(fleet.resolvedScope == .all)
        #expect(fleet.selectedStore === alphaStore)

        await fleet.refresh(lifecycle: lifecycle)
        #expect(fleet.selectedStore === alphaStore)
        #expect(fleet.selectedFeature?.title == "Alpha shared")

        #expect(fleet.open(betaTarget))
        #expect(fleet.selectedStore === betaStore)
        #expect(fleet.selectedFeature?.title == "Beta shared")
        #expect(betaStore.selectedFeatureID == "shared")
        // Opening a feature never changes the browsing scope.
        #expect(fleet.resolvedScope == .all)

        // A target for a machine that is not configured is ignored rather than
        // redirected to an existing host.
        #expect(!fleet.open(FirstMateFeatureTarget(machineID: "missing", featureID: "shared")))
        fleet.selectTarget(FirstMateFeatureTarget(machineID: "missing", featureID: "shared"))
        #expect(fleet.selectedTarget == betaTarget)
        fleet.selectTarget(nil)
        #expect(fleet.selectedTarget == nil)
    }

    @Test("Cancelling observation stops polling and releases loading state")
    func cancelledObservationStopsPolling() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        fleet.pollingInterval = .milliseconds(5)
        let alpha = machine("alpha", "Alpha Mac")
        let gate = MobileFleetGate()
        let source = FirstMateMobileFleetSource(
            machine: alpha,
            configuration: configuration(alpha, "alpha-token"),
            client: SyntheticMobileFleetClient(list: { _ in try await gate.fetch().features })
        )
        let observation = Task { await fleet.observe(sources: [source], connectionGeneration: 11) }
        defer {
            observation.cancel()
            Task { await gate.cancel() }
        }
        try await gate.waitForRequest()
        try await waitForMobileFleetCondition("host loading") { fleet.hosts.first?.isLoading == true }

        observation.cancel()
        await gate.cancel()
        await observation.value

        #expect(fleet.hosts.first?.isLoading == false)
        let requests = await gate.requestCount
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.requestCount == requests)
        #expect(fleet.store(forMachineID: "alpha")?.features.isEmpty == true)
    }

    @Test("An unchanged poll publishes nothing and capabilities stay per host")
    func unchangedPollIsQuiet() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let lifecycle = fleet.activate(sources: [
            source(alpha, active: [feature(id: "waiting", title: "Waiting", status: "awaiting_direction")],
                   capabilityNames: ["first-mate-archive-v1"])
        ], connectionGeneration: 12)
        await fleet.refresh(lifecycle: lifecycle)
        #expect(fleet.hosts.first?.archiveSupported == true)
        #expect(fleet.attentionCount == 1)
        let revision = fleet.contentRevision

        await fleet.refresh(lifecycle: lifecycle)
        await fleet.refresh(lifecycle: lifecycle)
        #expect(fleet.contentRevision == revision)
        #expect(fleet.hosts.first?.lastUpdated != nil)
        #expect(fleet.hosts.first?.isLoading == false)
    }

    @Test("Retiring the fleet invalidates every store and its delayed operations")
    func retireAllInvalidatesStores() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let lifecycle = fleet.activate(sources: [source(alpha, active: [feature(id: "alpha", title: "Alpha")])], connectionGeneration: 13)
        await fleet.refresh(lifecycle: lifecycle)
        let store = try #require(fleet.store(forMachineID: "alpha"))
        #expect(fleet.open(FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha")))
        let context = store.operationContext

        fleet.retireAll()
        #expect(fleet.store(forMachineID: "alpha") == nil)
        #expect(fleet.hosts.isEmpty)
        #expect(fleet.selectedTarget == nil)
        #expect(!(await store.create(
            title: "Delayed",
            goal: "Retired",
            cwd: "/tmp/synthetic",
            requestID: "retired-create",
            expectedContext: context
        )))
    }

    // MARK: - Helpers

    private func machine(_ id: String, _ name: String) -> HerdrMachine {
        HerdrMachine(id: id, name: name, urlString: "https://\(id).example.invalid")
    }

    private func configuration(_ machine: HerdrMachine, _ token: String) -> ServerConfiguration {
        ServerConfiguration(urlString: machine.urlString, token: token)!
    }

    private func snapshot(id: String, title: String, status: String = "running", archived: Bool = false) -> FirstMateSnapshot {
        var value = FirstMateDemo.newFeature(title: title, goal: "Synthetic goal for \(title)", cwd: "/tmp/synthetic", id: id)
        value.feature.status = status
        if archived { value.feature.archivedAt = FirstMateDemo.timestamp }
        return value
    }

    private func feature(id: String, title: String, status: String = "running", archived: Bool = false) -> FirstMateFeature {
        snapshot(id: id, title: title, status: status, archived: archived).feature
    }

    private func source(
        _ machine: HerdrMachine,
        active: [FirstMateFeature] = [],
        archived: [FirstMateFeature] = [],
        capabilityNames: [String] = []
    ) -> FirstMateMobileFleetSource {
        FirstMateMobileFleetSource(
            machine: machine,
            configuration: configuration(machine, "\(machine.id)-token"),
            client: SyntheticMobileFleetClient(
                snapshots: (active + archived).map { FirstMateSnapshot(feature: $0) },
                capabilityNames: capabilityNames
            )
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "FirstMateMobileFleetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

@MainActor
private func waitForMobileFleetCondition(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw MobileFleetWaitError.timedOut(description) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum MobileFleetWaitError: Error {
    case timedOut(String)
}

private actor MobileFleetGate {
    private var continuation: CheckedContinuation<FirstMateFeatureList, any Error>?
    private var requests = 0

    var requestCount: Int { requests }

    func fetch() async throws -> FirstMateFeatureList {
        requests += 1
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForRequest() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while continuation == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw MobileFleetWaitError.timedOut("gate request") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func succeed(_ response: FirstMateFeatureList) {
        continuation?.resume(returning: response)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor MobileFleetFeatureScript {
    private var pending: [Result<[FirstMateFeature], APIError>]
    private var last: Result<[FirstMateFeature], APIError>?

    init(_ responses: [Result<[FirstMateFeature], APIError>]) {
        pending = responses
    }

    func next() throws -> [FirstMateFeature] {
        let response: Result<[FirstMateFeature], APIError>
        if pending.isEmpty {
            guard let last else { return [] }
            response = last
        } else {
            response = pending.removeFirst()
            last = response
        }
        switch response {
        case .success(let features): return features
        case .failure(let error): throw error
        }
    }
}

private final class SyntheticMobileFleetClient: FirstMateClient, @unchecked Sendable {
    private let list: @Sendable (FirstMateFeatureScope) async throws -> [FirstMateFeature]
    private let capabilities: @Sendable () async throws -> FirstMateCapabilities
    private let snapshot: @Sendable (String) async throws -> FirstMateSnapshot

    init(
        list: @escaping @Sendable (FirstMateFeatureScope) async throws -> [FirstMateFeature],
        capabilities: @escaping @Sendable () async throws -> FirstMateCapabilities = { .init(ok: true, capabilities: []) },
        snapshot: @escaping @Sendable (String) async throws -> FirstMateSnapshot = { _ in throw APIError.invalidResponse }
    ) {
        self.list = list
        self.capabilities = capabilities
        self.snapshot = snapshot
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { try await capabilities() }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: try await list(.active))
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        .init(ok: true, features: try await list(scope))
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { try await snapshot(id) }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        throw APIError.invalidResponse
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        throw APIError.invalidResponse
    }
}

private extension SyntheticMobileFleetClient {
    convenience init(snapshots: [FirstMateSnapshot], capabilityNames: [String] = []) {
        let byID = Dictionary(snapshots.map { ($0.feature.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.init(
            list: { scope in
                switch scope {
                case .active: snapshots.filter { !$0.feature.isArchived }.map(\.feature)
                case .archived: snapshots.filter { $0.feature.isArchived }.map(\.feature)
                case .all: snapshots.map(\.feature)
                }
            },
            capabilities: { .init(ok: true, capabilities: capabilityNames) },
            snapshot: { id in
                guard let snapshot = byID[id] else { throw APIError.invalidResponse }
                return snapshot
            }
        )
    }

    convenience init(error: APIError) {
        self.init(
            list: { _ in throw error },
            capabilities: { throw error },
            snapshot: { _ in throw error }
        )
    }
}
