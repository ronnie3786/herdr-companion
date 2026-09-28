import Foundation

/// Optional provenance from the companion. Unknown fields remain server-owned.
/// Message identity and text stay unchanged when the conversation groups a
/// checkpoint and its closing reply from the same coordinator turn.
struct FirstMateMessageMetadata: Codable, Equatable, Sendable {
    var inReplyTo: String? = nil
    var turnID: String? = nil
    var visitID: String? = nil
    var checkpoint: Bool? = nil
    var assignmentID: String? = nil

    var isEmpty: Bool {
        inReplyTo == nil && turnID == nil && visitID == nil && checkpoint == nil && assignmentID == nil
    }

    enum CodingKeys: String, CodingKey {
        case inReplyTo = "in_reply_to", turnID = "turn_id", visitID = "visit_id"
        case checkpoint
        case assignmentID = "assignment_id"
    }
}

extension FirstMateMessageMetadata {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inReplyTo = try? container.decodeIfPresent(String.self, forKey: .inReplyTo)
        turnID = try? container.decodeIfPresent(String.self, forKey: .turnID)
        visitID = try? container.decodeIfPresent(String.self, forKey: .visitID)
        checkpoint = try? container.decodeIfPresent(Bool.self, forKey: .checkpoint)
        assignmentID = try? container.decodeIfPresent(String.self, forKey: .assignmentID)
    }
}
