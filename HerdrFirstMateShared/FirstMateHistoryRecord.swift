import Foundation

struct FirstMateHistoryRecord: Decodable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var title: String
    var status: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case featureID = "feature_id", createdAt = "created_at"
    }
}
