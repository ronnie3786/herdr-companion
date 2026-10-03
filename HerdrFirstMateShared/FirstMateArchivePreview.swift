import Foundation

struct FirstMateArchivePreview: Decodable, Sendable {
    var featureID: String
    var featureRevision: Int
    var token: String
    var resources: [FirstMateArchiveResource]
    var documentCount: Int
    var messageCount: Int
    var eligible: Bool = true
    var ineligibleReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case token, resources, eligible
        case ineligibleReason = "ineligible_reason"
        case featureID = "feature_id", featureRevision = "feature_revision"
        case documentCount = "document_count", messageCount = "message_count"
    }
}
