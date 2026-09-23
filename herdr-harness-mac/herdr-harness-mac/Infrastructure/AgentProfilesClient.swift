import Foundation

protocol AgentProfilesClient: Sendable {
    func fetchAgentProfiles() async throws -> AgentProfilesOverview
    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse
    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse
}
