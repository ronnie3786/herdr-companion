import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("Mounted global lead navigation", .serialized)
@MainActor
struct FirstMateLeadOpeningHostTests {
    @Test("Automatic failover cannot steal held exact feature or lead navigation", arguments: [false, true])
    func heldNavigation(lead: Bool) async throws {
        let fixture = try await LeadOpeningFixture()
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { fixture.fleet.selectedTarget?.machineID == "alpha" }
        let destination = lead ? fixture.leadID : "destination"
        await fixture.beta.hold(destination)
        let url = try #require(URL(string: lead
            ? "herdr://first-mate/lead?server_url=https%3A%2F%2Fbeta.example.invalid"
            : "herdr://first-mate?feature_id=destination&server_url=https%3A%2F%2Fbeta.example.invalid"))
        let request = try #require(FirstMateMobileOpenRequest(url: url))
        let navigation = fixture.model.openFirstMate(request, sources: fixture.sources)
        defer { navigation.cancel(); Task { await fixture.beta.release() } }
        try await fixture.wait { await fixture.beta.gate.arrived }
        let intent = fixture.fleet.chat.currentNavigationIntent
        fixture.alpha.features = .failure(.server(status: 503, message: "Synthetic offline"))
        await fixture.fleet.refreshChatIndex()
        await fixture.fleet.refreshChatIndex()
        #expect(fixture.fleet.leadChoice.current == "beta")
        await fixture.settle()
        #expect(fixture.fleet.chat.isCurrentNavigation(intent))
        #expect(fixture.fleet.selectedTarget?.machineID == "alpha", "An automatic opener must not alter a pending route's store context")
        await fixture.beta.release()
        await navigation.value
        let expected = FirstMateFeatureTarget(machineID: "beta", featureID: destination)
        #expect(fixture.fleet.chat.route?.target == expected)
        #expect(fixture.fleet.selectedTarget == expected)
        #expect(fixture.model.toastMessage == nil)
        // Keep the old global host mounted deliberately. Its next render and
        // task must not override a completed captured-owner route, even a lead.
        fixture.alpha.features = .success([])
        await fixture.fleet.refreshChatIndex()
        await fixture.settle()
        #expect(fixture.fleet.leadChoice.current == "alpha")
        #expect(fixture.fleet.chat.route?.target == expected)
        #expect(fixture.fleet.selectedTarget == expected)
        #expect(fixture.fleet.chat.isCurrentNavigation(intent))
    }

    @Test("Queued cancellation releases routing and stale completion cannot clear a newer held route")
    func routingCleanup() async throws {
        let fixture = try await LeadOpeningFixture()
        func request(_ host: String) throws -> FirstMateMobileOpenRequest {
            let url = try #require(URL(string:
                "herdr://first-mate?feature_id=destination&server_url=https%3A%2F%2F\(host).example.invalid"))
            return try #require(FirstMateMobileOpenRequest(url: url))
        }
        let cancelled = fixture.model.openFirstMate(try request("alpha"), sources: fixture.sources)
        cancelled.cancel()
        await cancelled.value
        #expect(!fixture.fleet.chat.isRouting)
        await fixture.beta.hold("destination")
        let old = fixture.model.openFirstMate(try request("beta"), sources: fixture.sources)
        defer { old.cancel(); Task { await fixture.beta.release() } }
        try await fixture.wait { await fixture.beta.gate.arrived }
        await fixture.alphaTransport.hold("destination")
        let newer = fixture.model.openFirstMate(try request("alpha"), sources: fixture.sources)
        defer { newer.cancel(); Task { await fixture.alphaTransport.release() } }
        try await fixture.wait { await fixture.alphaTransport.gate.arrived }
        let intent = fixture.fleet.chat.currentNavigationIntent
        await fixture.beta.release(); await old.value
        #expect(fixture.fleet.chat.isRouting)
        #expect(fixture.fleet.chat.isCurrentNavigation(intent))
        await fixture.alphaTransport.release(); await newer.value
        #expect(!fixture.fleet.chat.isRouting)
        #expect(fixture.fleet.chat.route?.target == .init(machineID: "alpha", featureID: "destination"))
    }

    @Test("Capability arrival opens one mounted lead and coverage preserves newer navigation")
    func capabilityArrival() async throws {
        let fixture = try await LeadOpeningFixture(loadIndex: false)
        fixture.mount()
        defer { fixture.unmount() }
        await fixture.fleet.refreshChatIndex()
        try await fixture.wait { fixture.fleet.selectedTarget?.machineID == "alpha" }
        let intent = fixture.fleet.chat.currentNavigationIntent
        await fixture.fleet.refreshChatIndex()
        await fixture.settle()
        #expect(fixture.alpha.featureCalls == 1)
        #expect(fixture.fleet.chat.isCurrentNavigation(intent))
        fixture.presentation.topmost = false
        let newerIntent = fixture.model.beginAppNavigation()
        await fixture.settle()
        #expect(fixture.fleet.chat.isCurrentNavigation(newerIntent))
        #expect(fixture.alpha.featureCalls == 1)
    }
}

@MainActor @Observable
private final class LeadOpeningPresentation { var topmost = true }

@MainActor
private struct LeadOpeningRoot: View {
    let fixture: LeadOpeningFixture
    var body: some View {
        FirstMateLeadScreen(model: fixture.model, fleet: fixture.fleet, goal: .constant(""),
            topmost: fixture.presentation.topmost, openFeature: { _ in }, openInfo: { _ in }, create: { _ in })
            .environment(\.scenePhase, .active)
    }
}

@MainActor
private final class LeadOpeningFixture {
    let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [],
        userDefaults: UserDefaults(suiteName: "LeadOpening.\(UUID())")!, bootstrapMachines: [])
    let alpha: SyntheticChatFleetClient
    let beta: LeadOpeningClient
    let alphaTransport: LeadOpeningClient
    let sources: [FirstMateMobileFleetSource]
    let leadID: String
    let presentation = LeadOpeningPresentation()
    var window: UIWindow?
    weak var previousWindow: UIWindow?
    var fleet: FirstMateMobileFleetStore { model.firstMateFleet }

    init(loadIndex: Bool = true) async throws {
        func client() -> SyntheticChatFleetClient {
            let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1"]))
            let lead = FirstMateDemo.chatWindowLead()
            client.lead = .init(feature: lead.feature, unread: false, workingOnReply: false, latestMessage: nil)
            client.snapshots = [lead.feature.id: lead, "destination": .init(feature: ChatFixtures.feature("destination", status: "draft"))]
            return client
        }
        alpha = client(); beta = LeadOpeningClient(base: client())
        alphaTransport = LeadOpeningClient(base: alpha)
        leadID = FirstMateDemo.chatWindowLead().feature.id
        func source(_ id: String, _ client: any FirstMateClient) -> FirstMateMobileFleetSource {
            let machine = ChatFixtures.machine(id)
            return .init(machine: machine, configuration: .init(urlString: machine.urlString, token: "synthetic"), client: client)
        }
        sources = [source("alpha", alphaTransport), source("beta", beta)]
        model.hasCompletedSetup = true
        model.selectedTab = .firstMate
        fleet.activate(sources: sources, connectionGeneration: model.connectionGeneration)
        fleet.chat.select(.lead)
        if loadIndex { await fleet.refreshChatIndex() }
    }
    func mount() {
        previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("A mounted lead host requires the test app's window scene"); return
        }
        let controller = UIHostingController(rootView: LeadOpeningRoot(fixture: self))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        self.window = window
    }
    func unmount() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousWindow?.makeKey()
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
    func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            window?.rootViewController?.view.layoutIfNeeded()
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "mounted lead opening") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor LeadOpeningClient: FirstMateClient {
    let base: SyntheticChatFleetClient
    let gate = ChatTestGate()
    private var heldID: String?
    init(base: SyntheticChatFleetClient) { self.base = base }
    func hold(_ id: String) { heldID = id }
    func release() async { await gate.open(); heldID = nil }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { try await base.fetchFirstMateCapabilities() }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await base.fetchFirstMateFeatures() }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse { try await base.fetchFirstMateFleet() }
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse { try await base.fetchFirstMateLead() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        if heldID == id { await gate.wait() }
        return try await base.fetchFirstMateFeature(id)
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
