import Foundation

/// The server resolves and snapshots the project folder. The goal is also the
/// first user message, committed atomically with the feature and receipt.
struct FirstMateProjectFeatureRequest: Encodable, Equatable, Sendable {
    var title: String
    var goal: String
    var projectID: String
    var expectedProjectRevision: Int
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case title, goal
        case projectID = "project_id"
        case expectedProjectRevision = "expected_project_revision", requestID = "request_id"
    }
}
