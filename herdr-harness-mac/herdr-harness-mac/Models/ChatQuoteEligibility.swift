import Foundation

/// Only the three newest completed, text-bearing agent messages in the active
/// conversation are quotable. Tools, thinking, and user prompts consume no slots.
enum ChatQuoteEligibility {
    static func assistantIDs(in turns: [PiConversationTurn]) -> Set<String> {
        var ids: Set<String> = []
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                guard case let .assistant(block) = item,
                      block.status == .complete,
                      !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                ids.insert(block.id)
                if ids.count == 3 { return ids }
            }
        }
        return ids
    }

    static func hudExchangeIDs(in exchanges: [HerdrHudExchange]) -> Set<String> {
        Set(exchanges.reversed().lazy.filter {
            ($0.status == .completed || $0.status == .promoted)
                && $0.response?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.prefix(3).map(\.id))
    }
}
