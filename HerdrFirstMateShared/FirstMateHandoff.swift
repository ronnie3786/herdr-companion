import Foundation

/// The durable tracking record for a managed session handoff.
///
/// Its `documentID` is the authoritative provenance link for the functional
/// checkpoint document retained in `FirstMateSnapshot.documents`.
struct FirstMateHandoff: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var assignmentID: String
    var featureID: String
    var predecessorGeneration: Int
    var predecessorSessionID: String
    var successorSessionID: String?
    var successorSessionFile: String?
    var successorOwner: String?
    var summary: String
    var documentID: String
    var status: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, summary, status
        case assignmentID = "assignment_id"
        case featureID = "feature_id"
        case predecessorGeneration = "predecessor_generation"
        case predecessorSessionID = "predecessor_session_id"
        case successorSessionID = "successor_session_id"
        case successorSessionFile = "successor_session_file"
        case successorOwner = "successor_owner"
        case documentID = "document_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
