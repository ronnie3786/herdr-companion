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
    var nativeSessionID: String? = nil
    /// Distinguishes an old response that omitted native_session_id from an
    /// explicit null acknowledging managed coordinator rotation.
    var includesNativeSessionID = true
    var coordinatorOwner: String? = nil
    var coordinatorContext: FirstMateCoordinatorContext? = nil
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
        case nativeSessionID = "native_session_id", coordinatorOwner = "coordinator_owner"
        case coordinatorContext = "coordinator_context"
        case usage, modelSelection = "model_selection"
    }
    var isArchived: Bool { archivedAt != nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.goal == rhs.goal
            && lhs.cwd == rhs.cwd
            && lhs.status == rhs.status
            && lhs.currentVisitID == rhs.currentVisitID
            && lhs.revision == rhs.revision
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.workItemID == rhs.workItemID
            && lhs.archivedAt == rhs.archivedAt
            && lhs.archiveReason == rhs.archiveReason
            && lhs.coordinatorModel == rhs.coordinatorModel
            && lhs.coordinatorThinking == rhs.coordinatorThinking
            && lhs.modelSettingsRevision == rhs.modelSettingsRevision
            && lhs.nativeSessionID == rhs.nativeSessionID
            && lhs.coordinatorOwner == rhs.coordinatorOwner
            && lhs.coordinatorContext == rhs.coordinatorContext
            && lhs.usage == rhs.usage
            && lhs.modelSelection == rhs.modelSelection
    }
}

extension FirstMateFeature {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        goal = try container.decode(String.self, forKey: .goal)
        cwd = try container.decode(String.self, forKey: .cwd)
        status = try container.decode(String.self, forKey: .status)
        currentVisitID = try container.decodeIfPresent(String.self, forKey: .currentVisitID)
        revision = try container.decode(Int.self, forKey: .revision)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        workItemID = try container.decodeIfPresent(String.self, forKey: .workItemID)
        archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
        archiveReason = try container.decodeIfPresent(String.self, forKey: .archiveReason)
        coordinatorModel = try container.decodeIfPresent(String.self, forKey: .coordinatorModel)
        coordinatorThinking = try container.decodeIfPresent(String.self, forKey: .coordinatorThinking)
        modelSettingsRevision = try container.decodeIfPresent(Int.self, forKey: .modelSettingsRevision)
        includesNativeSessionID = container.contains(.nativeSessionID)
        nativeSessionID = try container.decodeIfPresent(String.self, forKey: .nativeSessionID)
        coordinatorOwner = try container.decodeIfPresent(String.self, forKey: .coordinatorOwner)
        coordinatorContext = try container.decodeIfPresent(FirstMateCoordinatorContext.self, forKey: .coordinatorContext)
        usage = try container.decodeIfPresent(FirstMateUsage.self, forKey: .usage)
        modelSelection = try container.decodeIfPresent(FirstMateModelSelection.self, forKey: .modelSelection)
    }
}
