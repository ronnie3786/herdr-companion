import SwiftUI

@MainActor
struct ChatSkimTransport {
    let capabilities: () async throws -> ChatSkimCapabilities
    let request: (String, String?) async throws -> ChatSkimEnvelope
    let fetch: (String) async throws -> ChatSkimEnvelope
}

extension EnvironmentValues {
    @Entry var chatSkimTransport: ChatSkimTransport? = nil
}
