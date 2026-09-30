import Foundation

/// The synchronous reservation boundary. No Task may detach composer material.
/// Existing stores already retain text per feature and are owned per machine.
@MainActor
enum FirstMateMobileSubmission {
    static func begin(store: FirstMateStore, target: FirstMateFeatureTarget,
                      fleet: FirstMateMobileFleetStore, canControl: Bool,
                      reply: String? = nil, material: FirstMateMobileComposerDraft? = nil) -> FirstMateOutgoingMessage.Handle? {
        guard canControl, fleet.store(for: target) === store, fleet.selectedTarget == target,
              store.selectedFeatureID == target.featureID else { return nil }
        let draft = store.draft
        let context = store.operationContext
        if reply == nil, let material {
            guard material.isAlive(store: store, context: context), !material.blocksSending else { return nil }
        }
        let attachments = reply == nil ? material?.attachments ?? [] : []
        let dictation = reply == nil && material?.containsDictation == true
        let picks = FirstMateMentionOption.picksForSend(material?.picks ?? [], draft: draft,
            features: FirstMateMentionOption.taggableFeatures(fleet.conversations, machineID: target.machineID),
            crew: store.snapshots[target.featureID]?.assignments ?? [])
        let serialized = FirstMateMention.serializeComposer(draft, picks: picks)
        let payload = reply ?? PromptComposerView.submissionMessage(draft: serialized,
            uploadedPaths: attachments.compactMap(\.uploadedPath), containsDictation: dictation)
        let submission = FirstMateOutgoingMessage.Submission(draft: reply == nil ? draft : "",
            attachmentIDs: Set(attachments.map(\.id)), containsDictation: dictation)
        guard let handle = store.beginOutgoingMessage(payload, expectedContext: store.operationContext,
                                                       submission: submission) else { return nil }
        // Inline actions never consume a separately composed draft.
        if reply == nil, store.draft == draft {
            material?.detach(handle, text: draft)
            store.draft = ""
        }
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
