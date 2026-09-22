import Foundation

struct FirstMateSession: Codable, Equatable, Identifiable, Sendable {
    var nativeSessionID: String
    var featureID: String
    var assignmentID: String?
    var title: String
    var role: String
    var status: String
    var generation: Int
    var attempt: Int?
    var inputRevision: Int?
    var createdAt: String
    var updatedAt: String
    var ownershipStatus: String
    var kind: String? = nil
    var parentSessionID: String? = nil
    var usage: FirstMateUsage? = nil
    var modelSelection: FirstMateModelSelection? = nil
    var id: String { nativeSessionID }

    var kindDisplayName: String {
        switch kind {
        case "coordinator": "First Mate coordinator"
        case "worker": "Worker"
        case "advisor": "Advisor"
        default: role == "first_mate" ? "First Mate coordinator" : "Worker"
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, role, status, generation, attempt
        case nativeSessionID = "native_session_id", featureID = "feature_id", assignmentID = "assignment_id"
        case inputRevision = "input_revision", createdAt = "created_at", updatedAt = "updated_at"
        case ownershipStatus = "ownership_status"
        case kind, usage, modelSelection = "model_selection"
        case parentSessionID = "parent_session_id"
    }
}
