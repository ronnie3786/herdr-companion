import Foundation

struct AgentRolesOverview: Codable, Equatable, Sendable {
    let ok: Bool
    let capability: String
    let machineId: String
    let revision: Int
    let roles: [AgentRole]
    let skills: [AgentRoleSkill]
    let sources: [AgentRoleSkillSource]
    let warnings: [String]
    /// Per-role copy health is separate from the host's optional discovery folders.
    var missingRoleSkills: [String: [String]]? = nil
    var capabilities: [String]? = nil
    var teams: [AgentRoleTeam]? = nil

    var supportsPRReviewAgents: Bool { capabilities?.contains("pr-review-agents-v1") == true }
    var supportsPRReviewTeams: Bool { capabilities?.contains("pr-review-teams-v1") == true && teams != nil }

    func validated() throws -> Self {
        guard ok, capability == "agent-roles-v1", revision >= 0,
              Set(roles.map(\.id)).count == roles.count,
              Set(skills.map(\.id)).count == skills.count,
              Set((teams ?? []).map(\.id)).count == (teams ?? []).count else { throw APIError.invalidResponse }
        return self
    }
}
