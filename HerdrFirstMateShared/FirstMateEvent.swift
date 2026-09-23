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
