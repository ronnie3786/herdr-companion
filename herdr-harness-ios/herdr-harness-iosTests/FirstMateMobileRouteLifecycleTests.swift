import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Mobile route lifecycle fencing")
@MainActor
struct FirstMateMobileRouteLifecycleTests {
    @Test("A queued cold-start link cannot initialize a replacement connection")
    func queuedColdStartLink() async throws {
        let suite = "ColdStartRoute.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
                                  userDefaults: defaults, bootstrapMachines: [])
        model.selectedTab = .notes
        model.open(url: try #require(URL(string: "herdr://first-mate?feature_id=demo-session-continuity")))
        // Rotate synchronously before the route's queued MainActor task runs.
        model.connectionGeneration += 1
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.firstMateFleet.hosts.isEmpty)
        #expect(model.firstMateFleet.selectedTarget == nil && model.selectedTab == .notes)
    }

    @Test("A deferred assignment read cannot publish after its connection rotates")
    func assignmentConnectionRotation() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "RouteLifecycle.\(UUID())")!)
        let snapshot = FirstMateDemo.features(step: 0)[0]
        let assignment = try #require(snapshot.assignments.first)
        let base = SyntheticChatFleetClient(features: [snapshot.feature])
        base.snapshots = [snapshot.feature.id: snapshot]
        let gate = ChatTestGate()
        let delayed = DelayedMobileFeatureClient(base: base, gate: gate)
        let machine = ChatFixtures.machine("alpha")
        let source = FirstMateMobileFleetSource(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "old"), client: delayed)
        fleet.activate(sources: [source], connectionGeneration: 1)
        let url = try #require(URL(string: "herdr://first-mate?feature_id=\(snapshot.feature.id)&assignment_id=\(assignment.id)&server_url=https%3A%2F%2Falpha.example.invalid"))
        let request = try #require(FirstMateMobileOpenRequest(url: url))
        let navigation = Task { await fleet.chat.navigate(request, fleet: fleet) }
        defer { Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.arrived)
        fleet.activate(sources: [.init(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "replacement"), client: base)], connectionGeneration: 1)
        await gate.open()
        #expect(!(await navigation.value))
        #expect(fleet.chat.route == nil && fleet.selectedTarget == nil)
        #expect(fleet.store(forMachineID: "alpha")?.snapshots[snapshot.feature.id] == nil)
    }

    @Test("A cancelled old selected poll cannot replace a newer observer's wake-up handle")
    func supersededSelectedPoll() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "DriverRotation.\(UUID())")!)
        let feature = ChatFixtures.feature("feature")
        let oldClient = SyntheticChatFleetClient(features: [feature])
        let newClient = SyntheticChatFleetClient(features: [feature])
        let gate = ChatTestGate()
        let delayed = DelayedMobileFeatureClient(base: oldClient, gate: gate, delayedCall: 2)
        let machine = ChatFixtures.machine("alpha")
        let driver = FirstMateFleetDriver(fleet: fleet)
        driver.fleetInterval = .milliseconds(20)
        driver.selectedInterval = .milliseconds(20)
        let oldRun = Task {
            await driver.observe(sources: [.init(machine: machine,
                configuration: ServerConfiguration(urlString: machine.urlString, token: "old"), client: delayed)], connectionGeneration: 1)
        }
        defer { oldRun.cancel(); Task { await gate.open() } }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while oldClient.featureListCalls < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: feature.id)
        #expect(fleet.open(target))
        driver.setVisibleTarget(target)
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.arrived)
        oldRun.cancel()
        driver.setVisibleTarget(nil)
        let newRun = Task {
            await driver.observe(sources: [.init(machine: machine,
                configuration: ServerConfiguration(urlString: machine.urlString, token: "new"), client: newClient)], connectionGeneration: 1)
        }
        defer { newRun.cancel() }
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while newClient.featureListCalls < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        // Let the new inactive selected-store loop enter its long wait while
        // the cancelled old loop is still held inside the earlier refresh.
        try await Task.sleep(for: .milliseconds(30))
        await gate.open(); await oldRun.value
        let calls = newClient.featureCalls
        #expect(fleet.open(target))
        driver.setVisibleTarget(target)
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while newClient.featureCalls == calls, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(newClient.featureCalls > calls, "The new observer must retain the handle that wakes its 60-second wait")
        newRun.cancel(); await newRun.value
    }

    @Test("A deferred lead ensure cannot publish into a replacement store")
    func leadConnectionRotation() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "LeadRotation.\(UUID())")!)
        let snapshot = FirstMateDemo.chatWindowLead(), gate = ChatTestGate()
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1"]))
        client.snapshots = [snapshot.feature.id: snapshot]
        client.beforeEnsure = { await gate.wait() }
        let machine = ChatFixtures.machine("alpha")
        fleet.activate(sources: [.init(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "old"), client: client)], connectionGeneration: 1)
        await fleet.refreshChatIndex()
        client.lead = .init(feature: snapshot.feature, unread: false, workingOnReply: false, latestMessage: nil)
        let oldStore = try #require(fleet.store(forMachineID: "alpha"))
        let opening = Task { await fleet.chat.openLead(fleet: fleet, canControl: { _ in true }) }
        defer { Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.arrived)
        fleet.activate(sources: [.init(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "replacement"), client: client)], connectionGeneration: 1)
        await gate.open()
        #expect(await opening.value == nil)
        #expect(fleet.store(forMachineID: "alpha") !== oldStore)
        #expect(fleet.store(forMachineID: "alpha")?.leadSnapshot == nil)
        #expect(fleet.selectedTarget == nil && client.sent.isEmpty)
    }
}

private actor DelayedMobileFeatureClient: FirstMateClient {
    let base: SyntheticChatFleetClient
    let gate: ChatTestGate
    let delayedCall: Int
    private var calls = 0
    init(base: SyntheticChatFleetClient, gate: ChatTestGate, delayedCall: Int = 1) {
        self.base = base; self.gate = gate; self.delayedCall = delayedCall
    }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { try await base.fetchFirstMateCapabilities() }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await base.fetchFirstMateFeatures() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        calls += 1
        if calls == delayedCall { await gate.wait() }
        return try await base.fetchFirstMateFeature(id)
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
