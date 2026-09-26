import Foundation

enum FirstMateQuoteEligibility {
    /// Only the newest three completed, text-bearing assistant messages in the
    /// active feature are quotable. User and older messages remain copyable.
    static func messageIDs(in messages: [FirstMateMessage]) -> Set<String> {
        Set(messages.reversed().lazy.filter {
            $0.role == "assistant" && $0.isConversation
                && ["delivered", "completed", "complete"].contains($0.status)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(3).map(\.id))
    }

    static func canStage(
        sourceMessageID: String,
        snapshot: FirstMateSnapshot?,
        expectedContext: FirstMateStore.OperationContext,
        currentContext: FirstMateStore.OperationContext,
        canControl: Bool
    ) -> Bool {
        guard canControl,
              expectedContext == currentContext,
              let snapshot,
              expectedContext.matchesFeature(snapshot.feature.id),
              !["completed", "cancelled"].contains(snapshot.feature.status) else { return false }
        return messageIDs(in: snapshot.messages).contains(sourceMessageID)
    }
}
