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

    func validated() throws -> Self {
        guard ok, capability == "agent-roles-v1", revision >= 0,
              Set(roles.map(\.id)).count == roles.count,
              Set(skills.map(\.id)).count == skills.count else { throw APIError.invalidResponse }
        return self
    }
}
