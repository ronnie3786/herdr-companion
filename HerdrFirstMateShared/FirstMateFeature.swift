import Foundation

enum FirstMateArchiveReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case testSynthetic = "test/synthetic"
    case duplicate
    case noLongerRelevant = "no longer relevant"
    case superseded
    case other

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
}

enum FirstMateFeatureScope: String, Sendable {
    case active, archived, all
}

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
    var archivedAt: String? = nil
    var archiveReason: String? = nil
    var coordinatorModel: String? = nil
    var coordinatorThinking: String? = nil
    var modelSettingsRevision: Int? = nil
    var usage: FirstMateUsage? = nil
    var modelSelection: FirstMateModelSelection? = nil

    var modelDisplayName: String {
        guard let model = coordinatorModel, !model.isEmpty else { return "Host default" }
        return model.components(separatedBy: "/").last ?? model
    }

    enum CodingKeys: String, CodingKey {
        case id, title, goal, cwd, status, revision
        case currentVisitID = "current_visit_id", createdAt = "created_at", updatedAt = "updated_at"
        case workItemID = "work_item_id"
        case archivedAt = "archived_at", archiveReason = "archive_reason"
        case coordinatorModel = "coordinator_model", coordinatorThinking = "coordinator_thinking"
        case modelSettingsRevision = "model_settings_revision"
        case usage, modelSelection = "model_selection"
    }
    var isArchived: Bool { archivedAt != nil }
}
