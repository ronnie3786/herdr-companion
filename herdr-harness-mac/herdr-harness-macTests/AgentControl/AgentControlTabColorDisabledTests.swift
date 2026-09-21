import Foundation
import Security
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Agent control tab colors are read-only", .serialized)
@MainActor
struct AgentControlTabColorDisabledTests {
    @Test("Direct execution is rejected before any assignment or refresh")
    func directExecutionRejected() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = HerdrMachine(
            id: "synthetic-tab-color",
            name: "Synthetic",
            urlString: "https://synthetic.example.invalid"
        )
        let model = makeModel(defaults: defaults, machine: machine)
        let tabID = "\(machine.id)|w1:t1"
        model.chatTabColors.assign(.sage, to: tabID)

        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            pollInterval: .milliseconds(1),
            transportFactory: { _ in TabColorCommandTransport() }
        )
        controller.configure(
            model: model,
            shell: HerdrShellState(userDefaults: defaults),
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )

        do {
            _ = try await controller.executeForTesting(
                tabColorCommand(controller: controller, requestID: "direct-tab-color", machine: machine),
                serverMapping: ["srv_tab_color": machine.id]
            )
            Issue.record("Expected chat.tab-color to be rejected")
        } catch let error as AgentControlCommandError {
            #expect(error.code == "action_disabled")
            #expect(error.message.contains("read-only"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Manual state is untouched and label editing still works.
        #expect(model.chatTabColors.color(for: tabID) == .sage)
        #expect(model.chatTabColors.label(for: .sage) == "Sage")
        #expect(model.chatTabColors.rename(.sage, to: "Manual Workstream"))
        #expect(model.chatTabColors.label(for: .sage) == "Manual Workstream")
    }

    @Test("A queued chat.tab-color delivery fails disabled and never refreshes")
    func queuedExecutionRejected() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        TabColorRefreshURLProtocol.reset()
        let machine = HerdrMachine(
            id: "synthetic-tab-color",
            name: "Synthetic",
            urlString: "https://synthetic.example.invalid"
        )
        let model = makeModel(defaults: defaults, machine: machine)
        let tabID = "\(machine.id)|w1:t1"
        model.chatTabColors.assign(.sage, to: tabID)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TabColorRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        model.clientFactory = { HerdrAPIClient(configuration: $0, session: session) }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let transport = TabColorCommandTransport()
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            pollInterval: .milliseconds(5),
            transportFactory: { _ in transport }
        )
        await transport.install(
            tabColorCommand(controller: controller, requestID: "queued-tab-color", machine: machine)
        )
        controller.configure(
            model: model,
            shell: HerdrShellState(userDefaults: defaults),
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )

        controller.restartForTesting()
        try await transport.waitForAcknowledgementCount(1)
        let receipts = await transport.acknowledgements()
        #expect(receipts.count == 1)
        #expect(receipts.first?.status == "failed")
        #expect(receipts.first?.error?.code == "action_disabled")
        #expect(model.chatTabColors.color(for: tabID) == .sage)
        #expect(model.chatTabColors.label(for: .sage) == "Sage")
        #expect(TabColorRefreshURLProtocol.requestCount() == 0)
        controller.stopForTesting()
    }

    private func makeDefaults() throws -> (suite: String, defaults: UserDefaults) {
        let suite = "AgentControlTabColorDisabledTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        return (suite, defaults)
    }

    private func makeModel(defaults: UserDefaults, machine: HerdrMachine) -> HerdrAppModel {
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: [machine]
        )
        model.hasCompletedSetup = true
        return model
    }

    private func tabColorCommand(
        controller: AgentControlController,
        requestID: String,
        machine: HerdrMachine
    ) -> AgentControlCommand {
        AgentControlCommand(
            requestId: requestID,
            clientId: controller.clientID,
            instanceId: controller.instanceID,
            action: "chat.tab-color",
            target: AgentControlTarget(
                kind: "tab",
                serverId: "srv_tab_color",
                machineId: machine.id,
                workspaceId: "w1",
                tabId: "w1:t1"
            ),
            parameters: ["color": .string("rose")],
            expectedRevision: nil,
            status: "running",
            createdAt: "2030-01-01T00:00:00Z",
            expiresAt: "2030-01-01T00:00:30Z",
            result: nil,
            error: nil
        )
    }
}

actor TabColorCommandTransport: AgentControlTransport {
    enum WaitError: Error { case exceededBound }

    private var command: AgentControlCommand?
    private var didDeliver = false
    private var pollCount = 0
    private var acknowledgementRequests: [AgentControlResultRequest] = []

    func install(_ command: AgentControlCommand) {
        self.command = command
    }

    func capabilities() async throws -> AgentControlCapabilitiesResponse {
        AgentControlCapabilitiesResponse(
            ok: true,
            version: 1,
            serverId: "srv_tab_color",
            capabilities: ["agent-control-v1", "discovery-v1"]
        )
    }

    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse {
        AgentControlRegistrationResponse(ok: true, serverId: "srv_tab_color")
    }

    func poll(clientId: String, request: AgentControlPollRequest) async throws -> AgentControlPollResponse {
        pollCount += 1
        if !didDeliver, let command {
            didDeliver = true
            return AgentControlPollResponse(ok: true, command: command)
        }
        return AgentControlPollResponse(ok: true, command: nil)
    }

    func acknowledge(
        clientId: String,
        requestId: String,
        request: AgentControlResultRequest
    ) async throws -> AgentControlResultResponse {
        acknowledgementRequests.append(request)
        guard var acknowledged = command else { throw WaitError.exceededBound }
        acknowledged.status = request.status
        acknowledged.error = request.error
        return AgentControlResultResponse(ok: true, command: acknowledged)
    }

    func acknowledgements() -> [AgentControlResultRequest] { acknowledgementRequests }

    func waitForAcknowledgementCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while acknowledgementRequests.count < expected {
            if ContinuousClock.now > deadline { throw WaitError.exceededBound }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForPollCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while pollCount < expected {
            if ContinuousClock.now > deadline { throw WaitError.exceededBound }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class TabColorRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requests = Mutex<Int>(0)

    static func reset() {
        requests.withLock { $0 = 0 }
    }

    static func requestCount() -> Int {
        requests.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
