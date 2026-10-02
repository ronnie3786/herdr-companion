import Foundation

struct AgentRoleSkillSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let available: Bool
}
