import Foundation

struct AgentRoleMutation: Encodable, Sendable {
    let action: String
    let expectedRevision: Int
    let role: AgentRole?
    let roleId: String?
    let skillBundles: [AgentRoleSkillBundle]
}
