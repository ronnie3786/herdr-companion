import Foundation

struct FirstMateFeature: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var goal: String
    var cwd: String
    var status: String
    var currentVisitID: String?
    var revision: Int
    var createdAt: String
    var updatedAt: String
    var workItemID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, goal, cwd, status, revision
        case currentVisitID = "current_visit_id", createdAt = "created_at", updatedAt = "updated_at"
        case workItemID = "work_item_id"
    }
}
