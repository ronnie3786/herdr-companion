import Foundation

/// The synchronous reservation boundary. No Task may detach composer material.
/// Existing stores already retain text per feature and are owned per machine.
@MainActor
enum FirstMateMobileSubmission {
    static func begin(store: FirstMateStore, target: FirstMateFeatureTarget,
                      fleet: FirstMateMobileFleetStore, canControl: Bool,
                      reply: String? = nil) -> FirstMateOutgoingMessage.Handle? {
        guard canControl, fleet.store(for: target) === store, fleet.selectedTarget == target,
              store.selectedFeatureID == target.featureID else { return nil }
        let draft = store.draft
        let payload = reply ?? draft
        let submission = FirstMateOutgoingMessage.Submission(draft: reply == nil ? draft : "")
        guard let handle = store.beginOutgoingMessage(payload, expectedContext: store.operationContext,
                                                       submission: submission) else { return nil }
        // Inline actions never consume a separately composed draft.
        if reply == nil, store.draft == draft { store.draft = "" }
        return handle
    }

    static func retryHandle(_ outgoing: FirstMateOutgoingMessage, store: FirstMateStore,
                            target: FirstMateFeatureTarget, fleet: FirstMateMobileFleetStore,
                            canControl: Bool) -> FirstMateOutgoingMessage.Handle? {
        guard canControl, fleet.store(for: target) === store, fleet.selectedTarget == target,
              store.selectedFeatureID == target.featureID, outgoing.featureID == target.featureID,
              store.outgoingMessages(for: target.featureID).contains(where: { $0.id == outgoing.id && $0.state.isRetryable }),
              !store.isSubmitting(featureID: target.featureID) else { return nil }
        return .init(outgoingID: outgoing.id, requestID: outgoing.requestID, featureID: outgoing.featureID,
                     context: store.operationContext)
    }
}
