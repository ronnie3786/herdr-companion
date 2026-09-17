import Foundation

enum AgentControlWindow: String, Codable, Sendable {
    case main, settings, hud
    case activeWork = "active-work"
}

struct AgentControlTarget: Codable, Equatable, Sendable {
    var kind: String? = nil
    var serverId: String? = nil
    var serverURL: String? = nil
    var machineId: String? = nil
    var workspaceId: String? = nil
    var tabId: String? = nil
    var paneId: String? = nil
    var terminalId: String? = nil
    var sessionId: String? = nil
    var hudChatId: String? = nil
    var featureId: String? = nil

    /// Local snapshot metadata. This is deliberately omitted from CodingKeys:
    /// generation is not part of the locked server Target wire shape.
    var generation: Int? = nil

    enum CodingKeys: String, CodingKey {
        case kind, serverId, serverURL, machineId, workspaceId, tabId, paneId
        case terminalId, sessionId, hudChatId, featureId
    }
}

struct AgentControlUIState: Codable, Equatable, Sendable {
    var revision: Int
    var window: AgentControlWindow
    var segment: String
    var selection: AgentControlTarget?
    var modal: String?
    var enabled: Bool
}

struct AgentControlActionDescriptor: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var parameters: [String: PiJSONValue]
    var targetKinds: [String]
    var effect: String
    var enabled: Bool
    var disabledReason: String?
}

struct AgentControlCommandError: Codable, Equatable, LocalizedError, Sendable {
    var code: String
    var message: String

    var errorDescription: String? { message }
}

struct AgentControlCommand: Codable, Equatable, Sendable {
    var requestId: String
    var clientId: String
    var instanceId: String
    var action: String
    var target: AgentControlTarget?
    var parameters: [String: PiJSONValue]
    var expectedRevision: Int?
    var status: String
    var createdAt: String
    var expiresAt: String
    var result: [String: PiJSONValue]?
    var error: AgentControlCommandError?
}

struct AgentControlCapabilitiesResponse: Decodable, Sendable {
    let ok: Bool
    let version: Int
    let serverId: String
    let capabilities: [String]
}

struct AgentControlRegistrationRequest: Encodable, Sendable {
    let clientId: String
    let name: String
    let receiverToken: String
    let instanceId: String
    let state: AgentControlUIState
    let actions: [AgentControlActionDescriptor]
}

struct AgentControlRegistrationResponse: Decodable, Sendable {
    let ok: Bool
    let serverId: String
}

struct AgentControlPollRequest: Encodable, Sendable {
    let receiverToken: String
    let instanceId: String
    let state: AgentControlUIState
    let actions: [AgentControlActionDescriptor]?
}

struct AgentControlPollResponse: Decodable, Sendable {
    let ok: Bool
    let command: AgentControlCommand?
}

struct AgentControlResultRequest: Encodable, Equatable, Sendable {
    let receiverToken: String
    let instanceId: String
    let status: String
    let result: [String: PiJSONValue]?
    let error: AgentControlCommandError?
    let state: AgentControlUIState
}

struct AgentControlResultResponse: Decodable, Sendable {
    let ok: Bool
    let command: AgentControlCommand
}

enum AgentControlPresentationExpectation: Equatable, Sendable {
    case pane(id: String, mode: PaneDetailMode)
}

struct AgentControlExecutionResult: Equatable, Sendable {
    var values: [String: PiJSONValue]

    static func completed(_ values: [String: PiJSONValue] = [:]) -> Self {
        Self(values: values)
    }
}

extension AgentControlCommandError {
    static func invalid(_ message: String) -> Self { .init(code: "invalid_request", message: message) }
    static func stale(_ message: String) -> Self { .init(code: "stale_target", message: message) }
    static func notFound(_ message: String) -> Self { .init(code: "not_found", message: message) }
    static func disabled(_ message: String) -> Self { .init(code: "action_disabled", message: message) }
    static func conflict(_ message: String) -> Self { .init(code: "state_conflict", message: message) }
    static func unavailable(_ message: String) -> Self { .init(code: "unavailable", message: message) }
    static func failed(_ message: String) -> Self { .init(code: "action_failed", message: message) }
}
