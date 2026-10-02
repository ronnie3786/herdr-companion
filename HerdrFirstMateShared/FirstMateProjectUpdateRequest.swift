import Foundation

struct FirstMateProjectUpdateRequest: Encodable, Equatable, Sendable {
    var name: String
    var cwd: String
    var expectedRevision: Int
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case name, cwd
        case expectedRevision = "expected_revision", requestID = "request_id"
    }
}
