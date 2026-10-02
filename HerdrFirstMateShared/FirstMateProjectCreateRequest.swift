import Foundation

struct FirstMateProjectCreateRequest: Encodable, Equatable, Sendable {
    var name: String
    var cwd: String
    var requestID: String

    enum CodingKeys: String, CodingKey {
        case name, cwd
        case requestID = "request_id"
    }
}
