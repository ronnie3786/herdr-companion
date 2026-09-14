import Foundation

struct FirstMateVisit: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var stageKey: String
    var title: String
    var status: String
    var revision: Int
    var createdAt: String?
    var predecessorVisitID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, revision
        case featureID = "feature_id", stageKey = "stage_key", createdAt = "created_at"
        case predecessorVisitID = "predecessor_visit_id"
    }
}
