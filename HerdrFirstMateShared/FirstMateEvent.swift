import Foundation

struct FirstMateEvent: Codable, Equatable, Identifiable, Sendable {
    var sequence: Int
    var id: String
    var featureID: String
    var type: String
    var summary: String
    var createdAt: String
    var recoveryCheckpoint: FirstMateRecoveryCheckpoint? = nil

    enum CodingKeys: String, CodingKey {
        case sequence, id, type, summary
        case featureID = "feature_id", createdAt = "created_at"
        case recoveryCheckpoint = "payload"
    }
}

extension FirstMateEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decode(Int.self, forKey: .sequence)
        id = try c.decode(String.self, forKey: .id)
        featureID = try c.decode(String.self, forKey: .featureID)
        type = try c.decode(String.self, forKey: .type)
        summary = try c.decode(String.self, forKey: .summary)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        // Other event payloads have unrelated schemas. Advisor-authored recovery
        // summaries may also omit the machine-observed workspace fields.
        if type == "recovery.checkpoint" {
            recoveryCheckpoint = try c.decodeIfPresent(FirstMateRecoveryCheckpoint.self, forKey: .recoveryCheckpoint)
        }
    }
}

extension FirstMateEvent {
    /// Journal milestones a person would want to see between conversations,
    /// including First Mate's private notes from background work. Session,
    /// handoff, and execution bookkeeping repeats on every turn and says nothing
    /// new; message records repeat the conversation itself.
    static func isMilestone(_ type: String) -> Bool {
        // Demo mode's synthetic journal uses its own `demo.` types.
        type.hasPrefix("visit.") || type.hasPrefix("demo.") || milestoneTypes.contains(type)
    }

    static let milestoneTypes: Set<String> = [
        "feature.created", "feature.revised", "feature.revised_selectively", "feature.pause", "feature.resume",
        "feature.archived", "feature.unarchived", "revision.reason",
        "assignment.queued", "assignment.outcome", "assignment.progress", "assignment.steered",
        "assignment.waiting_children", "assignment.recovery_exhausted",
        "advisor.assessment", "reliability.blocked", "reliability.restarted", "runtime.error",
        "coordinator.note",
    ]

    var isMilestone: Bool { Self.isMilestone(type) }
}
