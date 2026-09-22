import Foundation

struct FirstMateAssignment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var visitID: String
    var title: String
    var role: String
    var status: String
    var verdict: String?
    var nativeSessionID: String?
    var attempt: Int
    var generation: Int
    var inputRevision: Int
    var updatedAt: String
    var visitIDs: [String]?
    var usage: FirstMateUsage? = nil
    var subtreeUsage: FirstMateUsage? = nil
    var modelSelection: FirstMateModelSelection? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, role, status, verdict, attempt, generation
        case featureID = "feature_id", visitID = "visit_id", nativeSessionID = "native_session_id"
        case inputRevision = "input_revision", updatedAt = "updated_at"
        case visitIDs = "visit_ids"
        case usage, subtreeUsage = "subtree_usage", modelSelection = "model_selection"
    }
}
