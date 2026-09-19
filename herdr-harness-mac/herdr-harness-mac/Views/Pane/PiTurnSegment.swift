import Foundation

/// Presentation-only partition of a turn's items into visible output and
/// collapsed runs of sub-process activity. Purely derived from `turn.items`,
/// the reducer's item order and indices are untouched. Empty assistant text
/// has no visual row; all visible content and failures stay in order.
struct PiWorkingGroup: Identifiable, Equatable {
    let id: String
    let items: [PiConversationItem]
    let toolCount: Int
    let thinkingCount: Int
    /// Title of the most recent tool in the group, via `PiToolPresentation`
    /// (e.g. "Command", "Read"). `nil` when the group has no tool.
    let latestToolTitle: String?
    /// The turn is active, an assistant/thinking block is still streaming, or
    /// a tool is still waiting/running.
    let isLive: Bool
    let failureCount: Int

    var stepCount: Int { items.count }
    var hasFailure: Bool { failureCount > 0 }
}

enum PiTurnSegment: Identifiable, Equatable {
    case output(PiConversationItem)
    case working(PiWorkingGroup)

    var id: String {
        switch self {
        case let .output(item): "output:\(item.id)"
        case let .working(group): group.id
        }
    }
}

enum PiTurnSegmentation {
    /// Collapses each *contiguous* run of working items into one group,
    /// preserving chronological order relative to output messages.
    static func segments(for items: [PiConversationItem]) -> [PiTurnSegment] {
        var segments: [PiTurnSegment] = []
        segments.reserveCapacity(items.count)
        var pending: [PiConversationItem] = []

        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.working(group(pending)))
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            // A text_start event can arrive before any visible token, and some
            // providers emit whitespace between tools. Those items must not
            // split activity groups or reserve empty transcript rows.
            if case let .assistant(block) = item,
               block.text.allSatisfy(\.isWhitespace) {
                if case .failed = block.status {
                    // Keep the error label even when the response text is empty.
                } else {
                    continue
                }
            }
            if item.isWorking {
                pending.append(item)
            } else {
                flush()
                segments.append(.output(item))
            }
        }
        flush()
        return segments
    }

    /// Presents one stable activity disclosure for an entire user turn. While
    /// the turn is active every assistant block remains inside the disclosure,
    /// even if Pi has already emitted `text_end`: only `agent_settled` clears
    /// `turn.isActive`, which is the reliable terminal boundary. Once settled,
    /// a successful concluding assistant message becomes the final answer. A
    /// message may contain several text parts, so all parts with its identity
    /// move outside together. Notices and failed assistant output remain
    /// outside the disclosure so terminal errors never require expansion.
    static func segments(
        for turn: PiConversationTurn,
        groupAllActivity: Bool
    ) -> [PiTurnSegment] {
        guard groupAllActivity else { return segments(for: turn.items) }

        let visibleItems = turn.items.filter { item in
            guard case let .assistant(block) = item,
                  block.text.allSatisfy(\.isWhitespace)
            else { return true }
            if case .failed = block.status { return true }
            return false
        }
        let finalAnswerIDs = finalAnswerIDs(in: visibleItems, isActive: turn.isActive)
        let activity = visibleItems.filter { item in
            switch item {
            case let .assistant(block):
                if finalAnswerIDs.contains(block.id) { return false }
                if case .failed = block.status { return false }
                return true
            case .thinking, .tool:
                return true
            case .notice:
                return false
            }
        }
        let terminalOutput = visibleItems.filter { item in
            switch item {
            case let .assistant(block):
                if finalAnswerIDs.contains(block.id) { return true }
                if case .failed = block.status { return true }
                return false
            case .notice:
                return true
            case .thinking, .tool:
                return false
            }
        }
        var result: [PiTurnSegment] = []
        if !activity.isEmpty {
            result.append(
                .working(
                    group(
                        activity,
                        id: "working:turn:\(turn.id)",
                        remainsLive: turn.isActive
                    )
                )
            )
        }
        result.append(contentsOf: terminalOutput.map(PiTurnSegment.output))
        return result
    }

    private static func finalAnswerIDs(
        in items: [PiConversationItem],
        isActive: Bool
    ) -> Set<String> {
        guard !isActive else { return [] }
        let literalConclusion = items.reversed().first { item in
            if case .thinking = item { return false }
            return true
        }
        let concludingItem: PiConversationItem?
        if case let .some(.notice(notice)) = literalConclusion,
           notice.tone == .neutral {
            // Informational notices may be journaled after a successful stop.
            // Only an explicit stop can cross that ordering ambiguity; older
            // nil-reason messages retain conservative literal ordering.
            concludingItem = items.reversed().first { item in
                switch item {
                case .thinking:
                    return false
                case let .notice(notice):
                    return notice.tone != .neutral
                case .assistant, .tool:
                    return true
                }
            }
            guard let candidate = concludingItem,
                  case let .assistant(block) = candidate,
                  block.stopReason?.caseInsensitiveCompare("stop") == .orderedSame
            else { return [] }
        } else {
            concludingItem = literalConclusion
        }
        guard let concludingItem,
              case let .assistant(concludingBlock) = concludingItem,
              concludingBlock.status == .complete,
              isSuccessfulStop(concludingBlock.stopReason)
        else { return [] }

        let messageID = messageIdentity(for: concludingBlock.id)
        let blocks = items.compactMap { item -> PiAssistantBlock? in
            guard case let .assistant(block) = item,
                  messageIdentity(for: block.id) == messageID
            else { return nil }
            return block
        }
        guard !blocks.isEmpty,
              blocks.allSatisfy({
                  $0.status == .complete && isSuccessfulStop($0.stopReason)
              }),
              !blocks.map(\.text).joined().allSatisfy(\.isWhitespace)
        else { return [] }
        return Set(blocks.map(\.id))
    }

    private static func messageIdentity(for blockID: String) -> String {
        guard let marker = blockID.range(of: ":text:", options: .backwards) else {
            return blockID
        }
        return String(blockID[..<marker.lowerBound])
    }

    private static func isSuccessfulStop(_ stopReason: String?) -> Bool {
        guard let stopReason else { return true }
        return stopReason.caseInsensitiveCompare("stop") == .orderedSame
    }

    private static func group(
        _ items: [PiConversationItem],
        id: String? = nil,
        remainsLive: Bool = false
    ) -> PiWorkingGroup {
        var toolCount = 0
        var thinkingCount = 0
        var latestToolTitle: String?
        var isLive = remainsLive
        var failureCount = 0
        for item in items {
            switch item {
            case let .tool(tool):
                toolCount += 1
                latestToolTitle = PiToolPresentation(tool: tool).title
                if tool.status == .waiting || tool.status == .running { isLive = true }
                if tool.status == .failed { failureCount += 1 }
            case let .thinking(block):
                thinkingCount += 1
                if block.isStreaming { isLive = true }
            case let .assistant(block):
                if case .streaming = block.status { isLive = true }
                if case .failed = block.status { failureCount += 1 }
            case let .notice(notice):
                if notice.tone == .error { failureCount += 1 }
            }
        }
        // Legacy groups use the first item's id. Whole-turn groups pass a turn
        // derived id so moving the final assistant message outside at settle
        // time cannot reset disclosure state or insertion animation.
        return PiWorkingGroup(
            id: id ?? "working:\(items.first?.id ?? "empty")",
            items: items,
            toolCount: toolCount,
            thinkingCount: thinkingCount,
            latestToolTitle: latestToolTitle,
            isLive: isLive,
            failureCount: failureCount
        )
    }
}
