import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@MainActor
struct AgentControlRegistryTests {
    @Test("Registry rejects unknown, missing, and extra parameters")
    func strictParameters() throws {
        #expect(throws: AgentControlCommandError.self) {
            try AgentControlRegistry.validate(action: "ui.segment", parameters: [:])
        }
        #expect(throws: AgentControlCommandError.self) {
            try AgentControlRegistry.validate(action: "ui.segment", parameters: ["segment": .string("chat"), "secret": .string("no")])
        }
        #expect(throws: AgentControlCommandError.self) {
            try AgentControlRegistry.validate(action: "ui.segment", parameters: ["segment": .string("not-real")])
        }
        try AgentControlRegistry.validate(action: "ui.segment", parameters: ["segment": .string("git")])
    }

    @Test("All advertised actions have strict object schemas and truthful disabled reasons")
    func descriptors() {
        let enabled = AgentControlRegistry.actions(enabled: true)
        #expect(enabled.map(\.id).contains("ui.open"))
        #expect(enabled.map(\.id).contains("chat.summarize"))
        #expect(enabled.allSatisfy { $0.parameters["additionalProperties"] == .bool(false) })
        let disabled = AgentControlRegistry.actions(enabled: false, disabledReason: "off")
        #expect(disabled.allSatisfy { !$0.enabled && $0.disabledReason == "off" })
    }

    @Test("Camel-case command decoding preserves exact wire route identity and omits local generation")
    func routeDecoding() throws {
        let data = Data(#"{"requestId":"route-1","clientId":"ui_test","instanceId":"instance","action":"ui.open","target":{"kind":"pane","serverId":"srv_test","machineId":"machine-a","workspaceId":"w1","tabId":"w1:t1","paneId":"w1:p2","terminalId":"term_2","sessionId":"session-2"},"parameters":{"view":"git"},"expectedRevision":11,"status":"running","createdAt":"2030-01-01T00:00:00Z","expiresAt":"2030-01-01T00:00:30Z"}"#.utf8)
        let command = try JSONDecoder().decode(AgentControlCommand.self, from: data)
        #expect(command.target?.serverId == "srv_test")
        #expect(command.target?.terminalId == "term_2")
        #expect(command.target?.sessionId == "session-2")
        #expect(command.expectedRevision == 11)
        #expect(command.parameters["view"] == .string("git"))
        #expect(command.target?.generation == nil)

        var localTarget = try #require(command.target)
        localTarget.generation = 42
        let encoded = try JSONEncoder().encode(localTarget)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["generation"] == nil)
    }

    @Test("A repeated request returns its cached terminal receipt and conflicting reuse is rejected")
    func requestCache() {
        var cache = AgentControlExecutionCache(limit: 2)
        let command = makeCommand(id: "request-1", action: "ui.refresh")
        let frozenState = AgentControlUIState(
            revision: 7,
            window: .main,
            segment: "activity",
            selection: nil,
            modal: nil,
            enabled: true
        )
        let receipt = AgentControlCachedReceipt(
            command: command,
            status: "completed",
            result: ["refreshed": .bool(true)],
            error: nil,
            state: frozenState
        )
        cache.store(receipt)
        #expect(cache.lookup(command) == .hit(receipt))
        #expect(receipt.state == frozenState)

        var conflict = command
        conflict.action = "ui.back"
        #expect(cache.lookup(conflict) == .conflict)
    }

    @Test("Receiver secret generation fails closed on Keychain read errors and malformed values")
    func keychainReadFailures() throws {
        let suite = "AgentControlIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let denied = AgentControlIdentityStore(
            defaults: defaults,
            storage: TestAgentControlSecretStorage(readStatus: errSecAuthFailed)
        )
        #expect(throws: AgentControlIdentityStore.IdentityError.self) {
            try denied.receiverToken(serverID: "srv_test", clientID: "ui_00000000-0000-0000-0000-000000000000")
        }

        let malformed = AgentControlIdentityStore(
            defaults: defaults,
            storage: TestAgentControlSecretStorage(readStatus: errSecSuccess, value: "not-a-token")
        )
        #expect(throws: AgentControlIdentityStore.IdentityError.self) {
            try malformed.receiverToken(serverID: "srv_test", clientID: "ui_00000000-0000-0000-0000-000000000000")
        }
    }

    private func makeCommand(id: String, action: String) -> AgentControlCommand {
        AgentControlCommand(
            requestId: id,
            clientId: "ui_test",
            instanceId: "instance",
            action: action,
            target: nil,
            parameters: [:],
            expectedRevision: nil,
            status: "running",
            createdAt: "2030-01-01T00:00:00Z",
            expiresAt: "2030-01-01T00:00:30Z",
            result: nil,
            error: nil
        )
    }
}
