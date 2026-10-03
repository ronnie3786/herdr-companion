import Foundation

struct FirstMateArchiveRequest: Encodable, Equatable, Sendable {
    var action = "archive"
    var requestID: String
    var reason: String?
    var expectedRevision: Int
    var previewToken: String
    var cleanupOptions: FirstMateArchiveOptions

    enum CodingKeys: String, CodingKey {
        case action, reason
        case requestID = "request_id", expectedRevision = "expected_revision"
        case previewToken = "preview_token", cleanupOptions = "cleanup_options"
    }
}
