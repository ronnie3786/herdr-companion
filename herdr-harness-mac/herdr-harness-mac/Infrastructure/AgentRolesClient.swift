import Foundation

protocol AgentRolesClient: Sendable {
    func fetchAgentRoles() async throws -> AgentRolesOverview
    func mutateAgentRoles(_ mutation: AgentRoleMutation) async throws -> AgentRolesOverview
}
