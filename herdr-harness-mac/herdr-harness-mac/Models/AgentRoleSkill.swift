import Foundation

struct AgentRoleSkill: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let source: String
    let path: String
    let estimatedTokens: Int

    var letter: String {
        guard let first = name.folding(options: [.diacriticInsensitive], locale: .current)
            .uppercased().first, first.isASCII, first.isLetter else { return "#" }
        return String(first)
    }
}
