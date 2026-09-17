import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@MainActor
struct AgentControlReceiverTests {
    @Test("Restarting the receiver cancels the prior generation and uses the injected transport")
    func generationCancellation() async throws {
        let suite = "AgentControlReceiverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let machine = HerdrMachine(id: "synthetic-machine", name: "Synthetic", urlString: "https://synthetic.example.invalid")
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: [machine]
        )
        let transport = BlockingAgentControlTransport()
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            pollInterval: .milliseconds(1),
            transportFactory: { _ in transport }
        )
        controller.configure(
            model: model,
            shell: HerdrShellState(userDefaults: defaults),
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )

        controller.restartForTesting()
        try await transport.waitForPollCount(1)
        let firstGeneration = controller.receiverGenerationForTesting
        controller.restartForTesting()
        try await transport.waitForCancellationCount(1)
        try await transport.waitForPollCount(2)

        #expect(controller.receiverGenerationForTesting == firstGeneration + 1)
        #expect(controller.hasPollingTaskForTesting)
        controller.stopForTesting()
        try await transport.waitForCancellationCount(2)
    }

    @Test("A claimed command with a stale expected revision is failed promptly without disconnecting the host")
    func staleRevisionReceiptKeepsHostAvailable() async throws {
        let suite = "AgentControlReceiverStaleRevisionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let machine = HerdrMachine(id: "stale-machine", name: "Stale", urlString: "https://stale.example.invalid")
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: [machine]
        )
        let shell = HerdrShellState(userDefaults: defaults)
        let transport = StaleRevisionAgentControlTransport()
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            pollInterval: .milliseconds(10),
            transportFactory: { _ in transport }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )
        let staleRevision = controller.currentState().revision
        shell.show(.activity, model: model)
        controller.stateDidChange()
        await transport.install(AgentControlCommand(
            requestId: "stale-revision",
            clientId: controller.clientID,
            instanceId: controller.instanceID,
            action: "ui.sidebar",
            target: nil,
            parameters: ["query": .string("must-not-apply")],
            expectedRevision: staleRevision,
            status: "running",
            createdAt: "2030-01-01T00:00:00Z",
            expiresAt: "2030-01-01T00:00:30Z",
            result: nil,
            error: nil
        ))

        controller.restartForTesting()
        try await transport.waitForAcknowledgementCount(1)
        try await transport.waitForPollCount(2)

        let receipts = await transport.acknowledgements()
        #expect(receipts.count == 1)
        #expect(receipts.first?.status == "failed")
        #expect(receipts.first?.error?.code == "state_conflict")
        #expect(model.searchText.isEmpty)
        #expect(controller.activeServerCount == 1)
        controller.stopForTesting()
    }

    @Test("Offline registration retries and acknowledgement retries preserve the frozen completion state")
    func retryAndFrozenAcknowledgement() async throws {
        let suite = "AgentControlReceiverRetryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let machine = HerdrMachine(id: "retry-machine", name: "Retry", urlString: "https://retry.example.invalid")
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: [machine]
        )
        let shell = HerdrShellState(userDefaults: defaults)
        let transport = RetryingAgentControlTransport()
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            pollInterval: .milliseconds(50),
            transportFactory: { _ in transport }
        )
        await transport.install(
            AgentControlCommand(
                requestId: "frozen-receipt",
                clientId: controller.clientID,
                instanceId: controller.instanceID,
                action: "ui.sidebar",
                target: nil,
                parameters: ["query": .string("synthetic")],
                expectedRevision: nil,
                status: "running",
                createdAt: "2030-01-01T00:00:00Z",
                expiresAt: "2030-01-01T00:00:30Z",
                result: nil,
                error: nil
            )
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )

        controller.restartForTesting()
        try await transport.waitForAcknowledgementCount(1)
        shell.show(.activity, model: model)
        controller.stateDidChange()
        try await transport.waitForAcknowledgementCount(2)

        let requests = await transport.acknowledgements()
        let capabilityAttempts = await transport.capabilityAttemptCount()
        #expect(capabilityAttempts >= 2)
        #expect(requests.count >= 2)
        let first = try #require(requests.first)
        let second = try #require(requests.dropFirst().first)
        #expect(first == second)
        #expect(first.state.segment != controller.currentState().segment)
        controller.stopForTesting()
    }
}

actor StaleRevisionAgentControlTransport: AgentControlTransport {
    enum WaitError: Error { case exceededBound }

    private var command: AgentControlCommand?
    private var didDeliver = false
    private var pollCount = 0
    private var ackRequests: [AgentControlResultRequest] = []

    func install(_ command: AgentControlCommand) {
        self.command = command
    }

    func capabilities() async throws -> AgentControlCapabilitiesResponse {
        AgentControlCapabilitiesResponse(
            ok: true,
            version: 1,
            serverId: "srv_stale",
            capabilities: ["agent-control-v1", "discovery-v1"]
        )
    }

    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse {
        AgentControlRegistrationResponse(ok: true, serverId: "srv_stale")
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
        ackRequests.append(request)
        guard var acknowledged = command else { throw WaitError.exceededBound }
        acknowledged.status = request.status
        acknowledged.error = request.error
        return AgentControlResultResponse(ok: true, command: acknowledged)
    }

    func acknowledgements() -> [AgentControlResultRequest] { ackRequests }

    func waitForAcknowledgementCount(_ expected: Int) async throws {
        for _ in 0..<5_000 {
            if ackRequests.count >= expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw WaitError.exceededBound
    }

    func waitForPollCount(_ expected: Int) async throws {
        for _ in 0..<5_000 {
            if pollCount >= expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw WaitError.exceededBound
    }
}

actor RetryingAgentControlTransport: AgentControlTransport {
    enum SyntheticError: Error { case offline, lostReply, exceededBound }

    private var capabilityAttempts = 0
    private var command: AgentControlCommand?
    private var didDeliver = false
    private var ackRequests: [AgentControlResultRequest] = []

    func install(_ command: AgentControlCommand) {
        self.command = command
    }

    func capabilities() async throws -> AgentControlCapabilitiesResponse {
        capabilityAttempts += 1
        if capabilityAttempts == 1 { throw SyntheticError.offline }
        return AgentControlCapabilitiesResponse(
            ok: true,
            version: 1,
            serverId: "srv_retry",
            capabilities: ["agent-control-v1", "discovery-v1"]
        )
    }

    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse {
        AgentControlRegistrationResponse(ok: true, serverId: "srv_retry")
    }

    func poll(clientId: String, request: AgentControlPollRequest) async throws -> AgentControlPollResponse {
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
        ackRequests.append(request)
        if ackRequests.count == 1 { throw SyntheticError.lostReply }
        guard var acknowledged = command else { throw SyntheticError.exceededBound }
        acknowledged.status = request.status
        return AgentControlResultResponse(ok: true, command: acknowledged)
    }

    func capabilityAttemptCount() -> Int { capabilityAttempts }
    func acknowledgements() -> [AgentControlResultRequest] { ackRequests }

    func waitForAcknowledgementCount(_ expected: Int) async throws {
        for _ in 0..<5_000 {
            if ackRequests.count >= expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SyntheticError.exceededBound
    }
}

actor BlockingAgentControlTransport: AgentControlTransport {
    enum WaitError: Error { case exceededBound }

    private var pollCount = 0
    private var cancellationCount = 0

    func capabilities() async throws -> AgentControlCapabilitiesResponse {
        AgentControlCapabilitiesResponse(
            ok: true,
            version: 1,
            serverId: "srv_synthetic",
            capabilities: ["agent-control-v1", "discovery-v1"]
        )
    }

    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse {
        AgentControlRegistrationResponse(ok: true, serverId: "srv_synthetic")
    }

    func poll(clientId: String, request: AgentControlPollRequest) async throws -> AgentControlPollResponse {
        pollCount += 1
        do {
            try await Task.sleep(for: .hours(1))
            return AgentControlPollResponse(ok: true, command: nil)
        } catch {
            cancellationCount += 1
            throw error
        }
    }

    func acknowledge(
        clientId: String,
        requestId: String,
        request: AgentControlResultRequest
    ) async throws -> AgentControlResultResponse {
        throw AgentControlCommandError.failed("No command is emitted by this transport.")
    }

    func waitForPollCount(_ expected: Int) async throws {
        for _ in 0..<1_000 {
            if pollCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.exceededBound
    }

    func waitForCancellationCount(_ expected: Int) async throws {
        for _ in 0..<1_000 {
            if cancellationCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.exceededBound
    }
}
