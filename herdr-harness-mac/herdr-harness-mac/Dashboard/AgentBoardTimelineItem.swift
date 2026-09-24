import Foundation

enum AgentBoardTimelineItem: Identifiable {
    case message(FirstMateMessage)
    case event(FirstMateEvent)

    var id: String {
        switch self {
        case .message(let value): "message:\(value.id)"
        case .event(let value): "event:\(value.id)"
        }
    }

    private var timestamp: String {
        switch self {
        case .message(let value): value.createdAt
        case .event(let value): value.createdAt
        }
    }

    static func items(in snapshot: FirstMateSnapshot) -> [Self] {
        let messages = snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }.map(Self.message)
        // Message journal records repeat the conversation. Keep operational
        // events, including recovery and checkpoints, as quiet timeline notes.
        let events = snapshot.events.filter { !$0.type.hasPrefix("message.") && !$0.summary.isEmpty }.map(Self.event)
        // The server's conversation order is authoritative when timestamps
        // tie. Random identifiers must not put an answer before its question.
        return (messages + events).enumerated().sorted {
            let left = HerdrTimestamp.date(from: $0.element.timestamp) ?? .distantPast
            let right = HerdrTimestamp.date(from: $1.element.timestamp) ?? .distantPast
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}
