import Foundation

/// Shared reply routing for the main First Mate screen, chat window, and lead HUD.
@MainActor
enum FirstMateSkimReplies {
    static func context(snapshot: FirstMateSnapshot, store: FirstMateStore, canControl: Bool) -> SkimReplyContext? {
        let featureID = snapshot.feature.id
        let operation = store.operationContext
        guard store.selectedFeatureID == featureID,
              !snapshot.feature.isArchived,
              !["completed", "cancelled"].contains(snapshot.feature.status),
              let message = snapshot.messages.last(where: \.isConversation),
              FirstMateFeedbackEligibility.isEligible(message) else { return nil }
        return SkimReplyContext(messageID: message.id, disabledReason: disabledReason(store: store, canControl: canControl)) { text in
            guard operation == store.operationContext,
                  disabledReason(store: store, canControl: canControl) == nil,
                  let current = store.snapshots[featureID],
                  !current.feature.isArchived,
                  !["completed", "cancelled"].contains(current.feature.status),
                  let latest = current.messages.last(where: \.isConversation),
                  latest.id == message.id, latest.text == message.text,
                  FirstMateFeedbackEligibility.isEligible(latest) else { return false }
            return await store.sendPreparedMessage(text, expectedContext: operation)
        }
    }

    private static func disabledReason(store: FirstMateStore, canControl: Bool) -> String? {
        let operation = store.operationContext
        let featureID = store.selectedFeatureID ?? ""
        return SkimReplyAvailability.disabledReason(
            connected: canControl && (store.controlAvailable || store.isDemo),
            busy: store.isSending || store.outgoingMessages(for: featureID).contains { $0.state.isPending }
                || store.sendFailure(for: featureID) != nil,
            hasDraft: !store.composerDraft(for: operation).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !store.composerDrafts.attachments(for: featureID).isEmpty
                || !store.composerDrafts.quotes(for: featureID).isEmpty
        )
    }
}
