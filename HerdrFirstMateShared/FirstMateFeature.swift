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
    var coordinatorModel: String? = nil
    var coordinatorThinking: String? = nil
    var modelSettingsRevision: Int? = nil
    var usage: FirstMateUsage? = nil

    var modelDisplayName: String {
        guard let model = coordinatorModel, !model.isEmpty else { return "Host default" }
        return model.components(separatedBy: "/").last ?? model
    }

    enum CodingKeys: String, CodingKey {
        case id, title, goal, cwd, status, revision
        case currentVisitID = "current_visit_id", createdAt = "created_at", updatedAt = "updated_at"
        case workItemID = "work_item_id"
        case coordinatorModel = "coordinator_model", coordinatorThinking = "coordinator_thinking"
        case modelSettingsRevision = "model_settings_revision"
        case usage
    }
}
