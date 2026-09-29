import Foundation

struct FirstMateLeadMessageBody: Encodable, Sendable {
    let text: String
    let requestID: String
    let context: FirstMateLeadContext

    enum CodingKeys: String, CodingKey {
        case text, context
        case requestID = "request_id"
    }
}

struct FirstMateLinkVisibilityBody: Encodable, Sendable {
    let hidden: Bool
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case hidden
        case requestID = "request_id"
    }
}
