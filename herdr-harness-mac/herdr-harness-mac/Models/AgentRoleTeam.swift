import Foundation

/// A saved PR review team. Agents belong to a team by its ID, so renaming a
/// team never changes its membership.
struct AgentRoleTeam: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
}
