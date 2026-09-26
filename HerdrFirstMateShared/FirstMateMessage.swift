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

    enum CodingKeys: String, CodingKey {
        case id, role, text, status, visibility
        case featureID = "feature_id", createdAt = "created_at"
    }

    /// Whether this row belongs in the human's conversation with First Mate.
    /// System updates and replies to routine background work stay out of chat.
    var isConversation: Bool {
        ["user", "human", "assistant"].contains(role) && visibility != "background"
    }
}
