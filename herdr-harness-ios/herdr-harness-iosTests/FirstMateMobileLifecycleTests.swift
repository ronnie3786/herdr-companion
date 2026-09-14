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
        let feature = try #require(model.firstMate.features.last)
        model.firstMate.select(feature.id)
        model.firstMate.draft = "Check the accessibility findings before implementation."
        model.selectedTab = .notes
        model.selectedTab = .firstMate
        await model.observeFirstMate()
        #expect(model.firstMate.selectedFeatureID == feature.id)
        #expect(model.firstMate.draft == "Check the accessibility findings before implementation.")
    }

    @Test("Host selection clears the previous feature and resource before fetching the new host")
    func switchingHostsFencesVisibleData() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let document = try #require(model.firstMate.snapshot?.documents.first)
        await model.firstMate.open(.document(document))
        model.firstMate.draft = "Only for the first host"
        let other = try #require(model.machines.first { $0.id != model.firstMateMachineID })
        model.selectFirstMateMachine(id: other.id)
        #expect(model.firstMateMachineID == other.id)
        #expect(model.firstMate.snapshot == nil)
        #expect(model.firstMate.openedResource == nil)
        #expect(model.firstMate.draft.isEmpty)
        await model.observeFirstMate()
        #expect(!model.firstMate.features.isEmpty)
    }

    @Test("Connection changes fence First Mate immediately, before the next SwiftUI task")
    func changedConnectionClearsDataSynchronously() async {
        let model = makeModel()
        await model.observeFirstMate()
        model.firstMate.draft = "Old connection"
        model.connectionGeneration += 1
        #expect(model.firstMate.features.isEmpty)
        #expect(model.firstMate.draft.isEmpty)
        #expect(model.firstMate.openedResource == nil)
    }

    @Test("An unknown host cannot redirect the feature conversation")
    func invalidSelectionLeavesHostAlone() async {
        let model = makeModel()
        await model.observeFirstMate()
        let selected = model.firstMateMachineID
        let feature = model.firstMate.selectedFeatureID
        model.selectFirstMateMachine(id: "missing-host")
        #expect(model.firstMateMachineID == selected)
        #expect(model.firstMate.selectedFeatureID == feature)
    }

    @Test("The dedicated demo opens First Mate without changing ordinary demo navigation")
    func explicitDemoEntry() {
        #expect(makeModel().selectedTab == .firstMate)
        #expect(makeModel(arguments: ["-HerdrDemoMode"]).selectedTab == .workspaces)
    }

    @Test("Removing the last host clears its First Mate identity")
    func removedHostDoesNotLinger() async {
        let model = makeModel()
        await model.observeFirstMate()
        for id in model.machines.map(\.id) { model.removeMachine(id: id) }
        #expect(model.firstMateMachineID.isEmpty)
        #expect(model.firstMate.features.isEmpty)
        #expect(model.firstMate.openedResource == nil)
        #expect(!model.firstMateCanControl)
    }

    @Test("A cancelled old observer cannot populate a newly selected host")
    func cancelledObservationIsInert() async throws {
        let model = makeModel()
        await model.observeFirstMate()
        let other = try #require(model.machines.first { $0.id != model.firstMateMachineID })
        model.selectFirstMateMachine(id: other.id)
        let observation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.observeFirstMate()
        }
        await observation.value
        #expect(model.firstMate.features.isEmpty)
        #expect(!model.firstMate.hasLoaded)
        // The replacement observer is the one allowed to load the new host.
        await model.observeFirstMate()
        #expect(model.firstMate.hasLoaded)
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
