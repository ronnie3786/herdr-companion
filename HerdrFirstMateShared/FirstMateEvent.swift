import Foundation

struct FirstMateEvent: Codable, Equatable, Identifiable, Sendable {
    var sequence: Int
    var id: String
    var featureID: String
    var type: String
    var summary: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case sequence, id, type, summary
        case featureID = "feature_id", createdAt = "created_at"
    }
}
