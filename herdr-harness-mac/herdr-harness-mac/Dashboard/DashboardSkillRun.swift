import Foundation

struct DashboardSkillRun: Codable, Equatable, Identifiable, Sendable {
    var skillID: String
    var title: String
    var state: String
    var updatedAt: String?
    var id: String { skillID }
    var label: String {
        let symbol = switch state {
        case "finished", "done": "✓"
        case "running", "queued": "◐"
        case "failed", "interrupted": "✕"
        default: "○"
        }
        return "\(title) \(symbol)"
    }
    enum CodingKeys: String, CodingKey {
        case title, state
        case skillID = "skill_id", updatedAt = "updated_at"
    }
}
