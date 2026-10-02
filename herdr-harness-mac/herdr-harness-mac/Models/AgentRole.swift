import Foundation

/// A role is private to the companion on which its sessions run.
struct AgentRole: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let builtin: Bool
    let locked: Bool
    var name: String
    var whenToUse: String
    var systemPrompt: String
    var modelProfile: String
    var allowDelegation: Bool
    /// nil preserves Pi discovery. An empty array explicitly allows no skills.
    var skillIds: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, builtin, locked, name, whenToUse, systemPrompt, modelProfile, allowDelegation, skillIds
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(builtin, forKey: .builtin)
        try container.encode(locked, forKey: .locked)
        try container.encode(name, forKey: .name)
        try container.encode(whenToUse, forKey: .whenToUse)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(modelProfile, forKey: .modelProfile)
        try container.encode(allowDelegation, forKey: .allowDelegation)
        // Keep the migration state explicit when saving unrelated profile edits.
        try container.encode(skillIds, forKey: .skillIds)
    }

    static func custom() -> Self {
        Self(id: UUID().uuidString.lowercased(), builtin: false, locked: false,
             name: "New role", whenToUse: "", systemPrompt: "", modelProfile: "execution",
             allowDelegation: false, skillIds: [])
    }
}
