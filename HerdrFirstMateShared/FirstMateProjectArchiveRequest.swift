import Foundation

struct FirstMateProjectArchiveRequest: Encodable, Equatable, Sendable {
    var archived: Bool
    var expectedRevision: Int
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case archived
        case expectedRevision = "expected_revision", requestID = "request_id"
    }
}
