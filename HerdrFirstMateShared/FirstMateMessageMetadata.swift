import Foundation

/// Optional provenance from the companion. Unknown fields remain server-owned.
/// Message identity and text stay unchanged when the conversation groups a
/// checkpoint and its closing reply from the same coordinator turn.
struct FirstMateMessageMetadata: Codable, Equatable, Sendable {
    var inReplyTo: String? = nil
    var turnID: String? = nil
    var visitID: String? = nil
    var checkpoint: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case inReplyTo = "in_reply_to", turnID = "turn_id", visitID = "visit_id"
        case checkpoint
    }
}
