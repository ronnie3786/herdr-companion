import Foundation

struct FirstMateMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var role: String
    var text: String
    var status: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, role, text, status
        case featureID = "feature_id", createdAt = "created_at"
    }
}
