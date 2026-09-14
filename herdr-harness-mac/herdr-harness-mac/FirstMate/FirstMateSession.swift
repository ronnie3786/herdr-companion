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
    var id: String { nativeSessionID }

    enum CodingKeys: String, CodingKey {
        case title, role, status, generation, attempt
        case nativeSessionID = "native_session_id", featureID = "feature_id", assignmentID = "assignment_id"
        case inputRevision = "input_revision", createdAt = "created_at", updatedAt = "updated_at"
        case ownershipStatus = "ownership_status"
    }
}
