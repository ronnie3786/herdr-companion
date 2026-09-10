import Foundation

/// Quoting is a follow-up on the latest agent output, never an annotation on
/// user prompts, tools, thinking, or an older conversation chapter.
enum ChatQuoteEligibility {
    static func latestAssistantID(in turns: [PiConversationTurn]) -> String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                guard case let .assistant(block) = item else { continue }
                // A new in-progress/failed answer supersedes the old one too.
                guard block.status == .complete, !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return block.id
            }
        }
        return nil
    }

    static func latestHUDExchangeID(in exchanges: [HerdrHudExchange]) -> String? {
        guard let latest = exchanges.last(where: { $0.response?.isEmpty == false }),
              latest.status == .completed || latest.status == .promoted else { return nil }
        return latest.id
    }
}
