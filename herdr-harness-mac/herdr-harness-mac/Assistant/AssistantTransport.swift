import Foundation

/// The session never resolves a machine from current UI selection.
@MainActor
struct AssistantTransport {
    var capabilities: () async throws -> AssistantCapabilities
    var start: (AssistantRequest) async throws -> HeadlessAgentRun
    var fetch: (String) async throws -> HeadlessAgentRun
    var stop: (String) async throws -> HeadlessAgentRun
    var models: () async throws -> AgentModelCatalogResponse
    var promote: (String) async throws -> HeadlessAgentRun
    var openAgent: (String) -> Void
}
