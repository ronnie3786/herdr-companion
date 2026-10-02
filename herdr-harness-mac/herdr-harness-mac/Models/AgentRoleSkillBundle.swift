import Foundation

/// An explicit copy of a selected skill package, never a reference to a remote path.
struct AgentRoleSkillBundle: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let source: String
    let files: [AgentRoleSkillFile]
}

struct AgentRoleSkillFile: Codable, Equatable, Sendable {
    let path: String
    let content: String
    let executable: Bool
}
