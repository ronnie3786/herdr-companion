import Foundation

struct ChatSkimSource: Equatable, Sendable {
    let messageID: String
    let reply: String
    let question: String?

    var id: String { "\(messageID):\(reply.hashValue):\(question?.hashValue ?? 0)" }

    /// Only text from a successful terminal assistant message is skimmed.
    /// Tool commentary, streaming turns, errors, and cancelled replies stay full.
    static func sources(in turn: PiConversationTurn) -> [String: Self] {
        let eligible = PiTurnSegmentation.finalAnswerIDs(in: turn.items, isActive: turn.isActive)
        let blocks = turn.items.compactMap { item -> PiAssistantBlock? in
            guard case let .assistant(block) = item, eligible.contains(block.id) else { return nil }
            return block
        }
        return Dictionary(blocks.map { block in
            (block.id, Self(messageID: block.id, reply: block.text, question: turn.user?.text))
        }, uniquingKeysWith: { first, _ in first })
    }

}
