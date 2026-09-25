import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("First Mate mobile lifecycle", .serialized)
@MainActor
struct FirstMateMobileLifecycleTests {
    @Test("Leaving and returning to First Mate preserves the selected feature and draft")
    func foregroundReturnPreservesConversation() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        let row = try #require(fleet.visibleRows.first(where: { $0.machineID == "demo1" }))
        #expect(fleet.open(row.target))
        let store = try #require(fleet.store(for: row.target))
        store.draft = "Check the accessibility findings before implementation."
        model.selectedTab = .notes
        model.selectedTab = .firstMate
        await model.observeFirstMate()
        #expect(fleet.selectedTarget == row.target)
        #expect(store.draft == "Check the accessibility findings before implementation.")
    }

    @Test("Machine scope offers All Machines, filters one host, and restores the combined view")
    func machineScopeSelection() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet

        #expect(fleet.scope == .all)
        #expect(fleet.resolvedScope == .all)
        #expect(Set(fleet.visibleRows.map(\.machineID)) == ["demo1", "demo2"])

        model.selectFirstMateScope(.machine("demo1"))
        #expect(fleet.resolvedScope == .machine("demo1"))
        #expect(!fleet.visibleRows.isEmpty)
        #expect(fleet.visibleRows.allSatisfy { $0.machineID == "demo1" })

        model.selectFirstMateScope(.machine("demo2"))
        #expect(fleet.visibleRows.allSatisfy { $0.machineID == "demo2" })

        model.selectFirstMateScope(.all)
        #expect(Set(fleet.visibleRows.map(\.machineID)) == ["demo1", "demo2"])
    }

    @Test("Opening a feature keeps the browsing scope unchanged")
    func openingAFeatureNeverChangesScope() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        model.selectFirstMateScope(.machine("demo2"))
        let row = try #require(fleet.visibleRows.first)
        #expect(fleet.open(row.target))
        #expect(fleet.resolvedScope == .machine("demo2"))
        await model.observeFirstMate()
        #expect(fleet.resolvedScope == .machine("demo2"))
        #expect(fleet.selectedTarget == row.target)
    }

    @Test("The synthetic demo exposes host-owned lists with distinct composite identities")
    func demoExposesHostOwnedLists() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet

        #expect(fleet.hosts.map(\.machineID) == ["demo1", "demo2"])
        // The two hosts share a feature ID. Composite targets keep them apart.
        let duplicates = fleet.visibleRows.filter { $0.featureID == "demo-session-continuity" }
        #expect(Set(duplicates.map(\.machineID)) == ["demo1", "demo2"])
        #expect(Set(duplicates.map(\.target)).count == 2)
        // The second host also owns a feature the first does not have.
        #expect(
            fleet.feature(for: FirstMateFeatureTarget(machineID: "demo2", featureID: "demo2-release-checklist"))?.title
                == "Ship the release checklist"
        )
        #expect(
            fleet.feature(for: FirstMateFeatureTarget(machineID: "demo1", featureID: "demo2-release-checklist")) == nil
        )

        let secondHost = FirstMateFeatureTarget(machineID: "demo2", featureID: "demo2-release-checklist")
        #expect(fleet.open(secondHost))
        #expect(fleet.selectedStore === fleet.store(forMachineID: "demo2"))
        #expect(fleet.selectedFeature?.title == "Ship the release checklist")
    }

    @Test("Create destination is explicit from All Machines and preselected for one host")
    func createDestinationSelection() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet

        // All Machines with two hosts requires an explicit destination.
        fleet.beginCreating()
        #expect(fleet.isCreating)
        #expect(fleet.creationMachineID == nil)
        fleet.isCreating = false

        // A single-machine scope preselects its host.
        model.selectFirstMateScope(.machine("demo2"))
        fleet.beginCreating()
        #expect(fleet.creationMachineID == "demo2")
        fleet.isCreating = false

        // All Machines with exactly one configured host has only one choice.
        let single = makeModel()
        await single.observeFirstMate()
        single.machines = [try #require(single.machines.first)]
        await single.observeFirstMate()
        single.firstMateFleet.beginCreating()
        #expect(single.firstMateFleet.creationMachineID == single.machines.first?.id)
    }

    @Test("A removed creation host dismisses the create sheet without substitution")
    func removedCreationHostClearsSheet() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        model.selectFirstMateScope(.machine("demo2"))
        fleet.beginCreating()
        #expect(fleet.creationMachineID == "demo2")

        model.removeMachine(id: "demo2")
        #expect(fleet.creationMachineID == nil)
        #expect(!fleet.isCreating)
        #expect(!model.firstMateCanControl(machineID: "demo2"))
    }

    @Test("Connection changes fence First Mate immediately, before the next SwiftUI task")
    func changedConnectionClearsDataSynchronously() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        let row = try #require(fleet.visibleRows.first)
        let store = try #require(fleet.store(for: row.target))
        store.draft = "Old connection"
        fleet.beginCreating()

        model.connectionGeneration += 1
        #expect(store.features.isEmpty)
        #expect(store.draft.isEmpty)
        #expect(fleet.hosts.isEmpty)
        #expect(fleet.selectedTarget == nil)
        #expect(!fleet.isCreating)
        #expect(fleet.creationMachineID == nil)
    }

    @Test("An unknown host cannot redirect the feature conversation or the scope")
    func invalidSelectionLeavesHostAlone() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        let target = try #require(fleet.visibleRows.first?.target)
        #expect(fleet.open(target))

        let missing = FirstMateFeatureTarget(machineID: "missing-host", featureID: target.featureID)
        #expect(!fleet.open(missing))
        fleet.selectTarget(missing)
        #expect(fleet.selectedTarget == target)
        model.selectFirstMateScope(.machine("missing-host"))
        #expect(fleet.resolvedScope == .all)
        #expect(fleet.visibleRows.contains { $0.target == target })
    }

    @Test("The dedicated demo opens First Mate without changing ordinary demo navigation")
    func explicitDemoEntry() {
        #expect(makeModel().selectedTab == .firstMate)
        #expect(makeModel(arguments: ["-HerdrDemoMode"]).selectedTab == .workspaces)
    }

    @Test("Removing every host clears the fleet and its control")
    func removedHostDoesNotLinger() async {
        let model = makeModel()
        await model.observeFirstMate()
        for id in model.machines.map(\.id) { model.removeMachine(id: id) }
        #expect(model.firstMateFleet.hosts.isEmpty)
        #expect(model.firstMateFleet.visibleRows.isEmpty)
        #expect(model.firstMateFleet.selectedTarget == nil)
        #expect(!model.firstMateCanControlVisibleHosts)
        #expect(model.firstMateScopeLabel == "All Machines")
    }

    @Test("A cancelled old observer cannot populate a newly activated roster")
    func cancelledObservationIsInert() async {
        let model = makeModel()
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        fleet.retireAll()
        let observation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.observeFirstMate()
        }
        await observation.value
        #expect(fleet.hosts.isEmpty)
        // The replacement observer is the one allowed to load the roster.
        await model.observeFirstMate()
        #expect(fleet.hosts.map(\.machineID) == ["demo1", "demo2"])
        #expect(!fleet.visibleRows.isEmpty)
    }

    @Test("String notification overrides honor the same values as launch arguments", arguments: [false, true])
    func stringNotificationDefaults(_ enabled: Bool) throws {
        let suite = "first-mate-notification-override-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Launch argument defaults are strings, unlike a saved Settings toggle.
        defaults.set(enabled ? "YES" : "NO", forKey: "herdr.smartAlerts")
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
                                  userDefaults: defaults, bootstrapMachines: [])
        #expect(model.smartAlertsEnabled == enabled)
    }

    #if DEBUG
    @Test("Reconnecting the UI test host retains its ephemeral authentication token")
    func fixtureAuthenticationSurvivesRuntimePreparation() throws {
        let model = makeModel(arguments: ["-HerdrUITestServerURL", "http://localhost:9092", "-HerdrUITestAPIToken", "synthetic-ui-token"])
        var preparedConfigurations: [ServerConfiguration] = []
        model.clientFactory = { configuration in
            preparedConfigurations.append(configuration)
            return HerdrAPIClient(configuration: configuration)
        }
        let machine = try #require(model.machines.first)
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        #expect(preparedConfigurations.count == 1)
        #expect(preparedConfigurations.first?.token == "synthetic-ui-token")
    }
    #endif

    private func makeModel(arguments: [String] = ["-HerdrFirstMateDemo"]) -> HerdrAppModel {
        let defaults = UserDefaults(suiteName: "first-mate-mobile-tests-\(UUID().uuidString)")!
        return HerdrAppModel(credentials: TestCredentialStore(), arguments: arguments,
                             userDefaults: defaults, bootstrapMachines: [])
    }
}
