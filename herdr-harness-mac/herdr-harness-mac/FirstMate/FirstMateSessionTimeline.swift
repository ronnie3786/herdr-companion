import Foundation

enum FirstMateSessionTimeline {
    static func turns(_ messages: [FirstMateSessionMessage], sessionID: String, isRunning: Bool) -> [PiConversationTurn] {
        var turns: [PiConversationTurn] = []
        var current = PiConversationTurn(id: "\(sessionID):leading", items: [], isActive: false)
        for (offset, message) in messages.enumerated() {
            let id = "\(sessionID):\(message.id ?? String(message.index ?? offset))"
            switch message.role {
            case "user", "human":
                if current.hasVisibleContent { turns.append(current) }
                current = PiConversationTurn(id: id, user: .init(id: id, text: message.text), items: [], isActive: false)
            case "assistant":
                if let thinking = message.thinking, !thinking.isEmpty {
                    current.items.append(.thinking(.init(id: id + ":thinking", text: thinking,
                        isStreaming: false, isRedacted: false, startedAt: nil)))
                }
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.stopReason == "error" {
                    current.items.append(.assistant(.init(id: id + ":text:0", text: message.text,
                        status: message.stopReason == "error" ? .failed("Agent response failed") : .complete,
                        stopReason: message.stopReason)))
                }
                for call in message.toolCalls ?? [] {
                    current.items.append(.tool(.init(id: id + ":tool:" + call.id, callID: call.id,
                        name: call.name, arguments: call.arguments, result: nil,
                        status: .waiting, startedAt: nil, finishedAt: nil)))
                }
            case "toolResult":
                if let callID = message.toolCallID, let index = current.items.firstIndex(where: {
                    if case let .tool(tool) = $0 { return tool.callID == callID }
                    return false
                }), case let .tool(tool) = current.items[index] {
                    current.items[index] = .tool(.init(id: tool.id, callID: tool.callID, name: tool.name,
                        arguments: tool.arguments, result: .string(message.text),
                        status: message.isError == true ? .failed : .succeeded, startedAt: nil, finishedAt: nil))
                } else {
                    current.items.append(.tool(.init(id: id, callID: message.toolCallID ?? id,
                        name: message.toolName ?? "Tool result", arguments: nil, result: .string(message.text),
                        status: message.isError == true ? .failed : .succeeded, startedAt: nil, finishedAt: nil)))
                }
            default: break
            }
        }
        if current.hasVisibleContent || isRunning { turns.append(current) }
        if !turns.isEmpty { turns[turns.count - 1].isActive = isRunning }
        // Saved history cannot assert that an unmatched tool is still running.
        for turnIndex in turns.indices where !turns[turnIndex].isActive {
            for itemIndex in turns[turnIndex].items.indices {
                if case var .tool(tool) = turns[turnIndex].items[itemIndex], tool.status == .waiting {
                    tool.status = .unavailable
                    tool.result = .string("No saved result is available for this tool call.")
                    turns[turnIndex].items[itemIndex] = .tool(tool)
                }
            }
        }
        return turns
    }
}
