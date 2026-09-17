import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
struct AgentControlWireContractTests {
    @Test("Receiver requests encode the shared camel-case wire shape")
    func receiverRequestEncoding() throws {
        let fixture = try AgentControlWireFixture.load()
        let registrationJSON = try fixture.object("registration")
        let registration = AgentControlRegistrationRequest(
            clientId: try fixture.string("clientId", in: registrationJSON),
            name: try fixture.string("name", in: registrationJSON),
            receiverToken: try fixture.string("receiverToken", in: registrationJSON),
            instanceId: try fixture.string("instanceId", in: registrationJSON),
            state: try fixture.decode(AgentControlUIState.self, registrationJSON["state"]),
            actions: try fixture.decode([AgentControlActionDescriptor].self, registrationJSON["actions"])
        )
        #expect(try fixture.matchesEncoded(registration, document: registrationJSON))

        let pollJSON = try fixture.object("poll")
        let poll = AgentControlPollRequest(
            receiverToken: try fixture.string("receiverToken", in: pollJSON),
            instanceId: try fixture.string("instanceId", in: pollJSON),
            state: try fixture.decode(AgentControlUIState.self, pollJSON["state"]),
            actions: nil
        )
        #expect(try fixture.matchesEncoded(poll, document: pollJSON))

        let acknowledgementJSON = try fixture.object("acknowledgement")
        let acknowledgement = AgentControlResultRequest(
            receiverToken: try fixture.string("receiverToken", in: acknowledgementJSON),
            instanceId: try fixture.string("instanceId", in: acknowledgementJSON),
            status: try fixture.string("status", in: acknowledgementJSON),
            result: try fixture.decode([String: PiJSONValue].self, acknowledgementJSON["result"]),
            error: nil,
            state: try fixture.decode(AgentControlUIState.self, acknowledgementJSON["state"])
        )
        #expect(try fixture.matchesEncoded(acknowledgement, document: acknowledgementJSON))
        #expect(fixture.receiverSecretIsAbsentFromPublicDocuments())
    }

    @Test("Claimed and acknowledged commands decode only the locked camel-case keys")
    func commandDecoding() throws {
        let fixture = try AgentControlWireFixture.load()
        let claimedJSON = try fixture.object("claimedCommand")
        let claimed = try fixture.decode(AgentControlCommand.self, claimedJSON)
        #expect(claimed.requestId == "contract-open-1")
        #expect(claimed.target?.serverId == fixture.serverID)
        #expect(claimed.target?.terminalId == "term_contract")
        #expect(claimed.target?.sessionId == "55555555-5555-4555-8555-555555555555")
        #expect(claimed.parameters["view"] == .string("git"))
        #expect(claimed.expectedRevision == 7)
        #expect(claimed.status == "running")
        #expect(claimedJSON["requestId"] != nil)
        #expect(claimedJSON["expectedRevision"] != nil)
        #expect(claimedJSON["createdAt"] != nil)
        #expect(claimedJSON["request_id"] == nil)
        #expect(claimedJSON["expected_revision"] == nil)
        #expect(claimedJSON["created_at"] == nil)
        #expect(try fixture.matchesEncoded(claimed, document: claimedJSON))

        var snakeCaseOnly = claimedJSON
        snakeCaseOnly["request_id"] = snakeCaseOnly.removeValue(forKey: "requestId")
        let snakeCaseData = try JSONSerialization.data(withJSONObject: snakeCaseOnly)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentControlCommand.self, from: snakeCaseData)
        }

        let pollResponse = try fixture.decode(
            AgentControlPollResponse.self,
            ["ok": true, "command": claimedJSON] as [String: Any]
        )
        #expect(pollResponse.ok)
        #expect(pollResponse.command == claimed)

        let completedJSON = try fixture.object("completedCommand")
        let resultResponse = try fixture.decode(
            AgentControlResultResponse.self,
            ["ok": true, "command": completedJSON] as [String: Any]
        )
        #expect(resultResponse.ok)
        #expect(resultResponse.command.status == "completed")
        #expect(resultResponse.command.result?["view"] == .string("git"))
        #expect(try fixture.matchesEncoded(resultResponse.command, document: completedJSON))

        let registrationResponse = try fixture.decode(
            AgentControlRegistrationResponse.self,
            try fixture.object("registrationResponse")
        )
        #expect(registrationResponse.ok)
        #expect(registrationResponse.serverId == fixture.serverID)
    }

    @Test("Targets omit local generation and registry schemas match the shared fixture")
    func targetAndSchemaCompatibility() throws {
        let fixture = try AgentControlWireFixture.load()
        let targetJSON = try fixture.object("target")
        var target = try fixture.decode(AgentControlTarget.self, targetJSON)
        #expect(target.generation == nil)
        target.generation = 42
        #expect(try fixture.matchesEncoded(target, document: targetJSON))

        var receivedWithLocalField = targetJSON
        receivedWithLocalField["generation"] = 99
        let decoded = try fixture.decode(AgentControlTarget.self, receivedWithLocalField)
        #expect(decoded.generation == nil)

        let registration = try fixture.object("registration")
        let expectedActions = try fixture.array("actions", in: registration)
        let expectedIDs = Set(expectedActions.compactMap { ($0 as? [String: Any])?["id"] as? String })
        let actualActions = AgentControlRegistry.actions(enabled: true).filter { expectedIDs.contains($0.id) }
        #expect(try fixture.matchesEncoded(actualActions, document: expectedActions))
    }
}

private struct AgentControlWireFixture {
    enum FixtureError: Error {
        case invalidRoot
        case missingValue(String)
        case wrongType(String)
    }

    let root: [String: Any]
    let serverID: String

    static func load(filePath: String = #filePath) throws -> Self {
        var repository = URL(fileURLWithPath: filePath)
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: repository.appending(path: "tests/fixtures/agent-control-v1.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverID = root["serverId"] as? String
        else {
            throw FixtureError.invalidRoot
        }
        return Self(root: root, serverID: serverID)
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let value = root[key] else { throw FixtureError.missingValue(key) }
        guard let object = value as? [String: Any] else { throw FixtureError.wrongType(key) }
        return object
    }

    func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] else { throw FixtureError.missingValue(key) }
        guard let string = value as? String else { throw FixtureError.wrongType(key) }
        return string
    }

    func array(_ key: String, in object: [String: Any]) throws -> [Any] {
        guard let value = object[key] else { throw FixtureError.missingValue(key) }
        guard let array = value as? [Any] else { throw FixtureError.wrongType(key) }
        return array
    }

    func decode<Value: Decodable>(_ type: Value.Type, _ document: Any?) throws -> Value {
        guard let document else { throw FixtureError.missingValue(String(describing: type)) }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return try JSONDecoder().decode(type, from: data)
    }

    func matchesEncoded<Value: Encodable>(_ value: Value, document: Any) throws -> Bool {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try canonicalData(encoded) == canonicalData(document)
    }

    func receiverSecretIsAbsentFromPublicDocuments() -> Bool {
        guard let token = root["receiverToken"] as? String else { return false }
        return ["registrationResponse", "claimedCommand", "completedCommand"].allSatisfy { key in
            guard let value = root[key],
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return false }
            return !text.contains(token) && !text.contains("receiverToken")
        }
    }

    private func canonicalData(_ document: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}
