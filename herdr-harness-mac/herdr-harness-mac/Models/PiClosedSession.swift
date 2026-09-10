import Foundation

/// Read-only local history. These excerpts never enter the active reducer or
/// agent context, and historical tool/permission controls cannot be replayed.
struct PiClosedSession: Codable, Equatable, Identifiable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let role: String
        let text: String
    }
    let id: String
    let closedAt: Date
    let entries: [Entry]
    let wasTruncated: Bool

    init(id: String, turns: [PiConversationTurn], wasTruncated: Bool, closedAt: Date = .now) {
        self.id = id
        self.closedAt = closedAt
        self.wasTruncated = wasTruncated
        self.entries = turns.flatMap { turn -> [Entry] in
            var entries: [Entry] = []
            if let user = turn.user { entries.append(Entry(id: "\(turn.id)-user", role: "You", text: user.text)) }
            for item in turn.items {
                let role: String
                let text: String
                switch item {
                case let .assistant(block): role = "Pi"; text = block.text
                case let .thinking(block): role = "Thinking"; text = block.isRedacted ? "Redacted" : block.text
                case let .tool(tool):
                    role = tool.name
                    text = [tool.argumentsDisplayString, tool.resultDisplayString].compactMap { $0 }.joined(separator: "\n\n")
                case let .notice(notice): role = notice.title; text = notice.detail ?? ""
                }
                if !text.isEmpty { entries.append(Entry(id: "\(turn.id)-\(item.id)", role: role, text: text)) }
            }
            return entries
        }
    }
}
