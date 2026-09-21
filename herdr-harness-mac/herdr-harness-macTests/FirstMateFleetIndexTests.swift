import Foundation
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
        let deadline = clock.now.advanced(by: .seconds(1))
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
