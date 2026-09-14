import Foundation

struct FirstMateDocument: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var visitID: String?
    var assignmentID: String?
    var nativeSessionID: String?
    var title: String
    var mediaType: String
    var contentHash: String
    var createdAt: String
    var content: String?
    var generation: Int?
    var inputRevision: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, content, generation
        case featureID = "feature_id", visitID = "visit_id", assignmentID = "assignment_id"
        case nativeSessionID = "native_session_id", mediaType = "media_type"
        case contentHash = "content_hash", createdAt = "created_at"
        case inputRevision = "input_revision"
    }
}
