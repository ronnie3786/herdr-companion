import Foundation

struct FirstMateMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var role: String
    var text: String
    var status: String
    var createdAt: String
    /// `conversation` or `background`. Companions before
    /// `first-mate-quiet-chat-v1` omit it; their messages all count as chat.
    var visibility: String? = nil
    /// A skim of a long reply (`first-mate-skim-v1`). Older companions omit it,
    /// and a malformed one decodes as nil: the reply shows in full either way.
    var skim: FirstMateSkim? = nil
    /// The crew assignment that wrote this message, from the companion's
    /// `metadata.assignment_id`. Nil for First Mate's and the human's own rows.
    var assignmentID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, role, text, status, visibility, skim, metadata
        case featureID = "feature_id", createdAt = "created_at"
    }

    private enum MetadataKeys: String, CodingKey {
        case assignmentID = "assignment_id"
    }

    init(id: String, featureID: String, role: String, text: String, status: String, createdAt: String,
         visibility: String? = nil, skim: FirstMateSkim? = nil, assignmentID: String? = nil) {
        self.id = id
        self.featureID = featureID
        self.role = role
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.visibility = visibility
        self.skim = skim
        self.assignmentID = assignmentID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        featureID = try c.decode(String.self, forKey: .featureID)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        status = try c.decode(String.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        skim = try? c.decodeIfPresent(FirstMateSkim.self, forKey: .skim)
        // Metadata is an open dictionary; anything but a string id is ignored.
        let metadata = try? c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
        assignmentID = (try? metadata?.decodeIfPresent(String.self, forKey: .assignmentID)) ?? nil
    }

    /// Encodes the same shape as before; `metadata` appears only when there is
    /// an assignment id to carry.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(featureID, forKey: .featureID)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(skim, forKey: .skim)
        if let assignmentID {
            var metadata = c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
            try metadata.encode(assignmentID, forKey: .assignmentID)
        }
    }

    /// Whether this row belongs in the human's conversation with First Mate.
    /// System updates and replies to routine background work stay out of chat.
    var isConversation: Bool {
        ["user", "human", "assistant"].contains(role) && visibility != "background"
    }
}
