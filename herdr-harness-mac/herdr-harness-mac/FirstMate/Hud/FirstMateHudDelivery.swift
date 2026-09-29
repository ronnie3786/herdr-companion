import Foundation
import Observation

/// One HUD message, kept even when opening the destination fails before a
/// message can be reserved. The client and connection check are pinned at
/// submission: a fleet fallback must never redirect an explicit retry.
@MainActor @Observable
final class FirstMateHudDelivery {
    let transcript: String
    let destinationLabel: String
    private(set) var isSending = false
    private(set) var isAccepted = false
    private(set) var error: String?

    @ObservationIgnored private let payload: String
    @ObservationIgnored private let store: FirstMateStore
    @ObservationIgnored private let featureID: String?
    @ObservationIgnored private let connectionIsCurrent: () -> Bool
    @ObservationIgnored private var handle: FirstMateOutgoingMessage.Handle?

    init(transcript: String, payload: String, destinationLabel: String,
         store: FirstMateStore, featureID: String? = nil,
         connectionIsCurrent: @escaping () -> Bool) {
        self.transcript = transcript
        self.payload = payload
        self.destinationLabel = destinationLabel
        self.store = store
        self.featureID = featureID
        self.connectionIsCurrent = connectionIsCurrent
    }

    /// No automatic retry, including after reconnection or a fleet refresh.
    /// Once transport starts, every explicit retry uses the frozen payload,
    /// lead context, destination, and request ID in the original reservation.
    @discardableResult
    func send() async -> Bool {
        guard !isSending, !isAccepted else { return false }
        guard connectionIsCurrent() else {
            error = "This destination's connection changed. Copy your message before starting again."
            return false
        }
        guard !Task.isCancelled else { return false }
        isSending = true
        error = nil
        defer { isSending = false }

        if handle == nil {
            if let featureID {
                store.select(featureID)
                if store.snapshots[featureID] == nil {
                    await store.refreshFeature(store.operationContext)
                }
            } else if store.leadFeatureID == nil || store.selectedFeatureID != store.leadFeatureID {
                guard await store.openLead() else {
                    error = "Could not open \(destinationLabel). \(store.error ?? "Check its connection and retry.")"
                    return false
                }
            }
            // Opening a conversation suspends. Revalidate before sending any
            // words, rather than using a connection removed during that wait.
            guard connectionIsCurrent(), !Task.isCancelled else {
                error = "Sending stopped before your message was submitted. Your words are kept here."
                return false
            }
            guard let reserved = store.beginOutgoingMessage(payload, expectedContext: store.operationContext) else {
                error = store.error ?? "This conversation isn't ready to send. Your words are kept here."
                return false
            }
            handle = reserved
            return settle(await store.completeOutgoingMessage(reserved))
        }
        guard let handle else { return false }
        return settle(await store.retryOutgoingMessage(handle))
    }

    /// Removes only local failed-send presentation. A message the server may
    /// already have accepted is never deleted or cancelled by discarding it.
    func discard() {
        guard !isSending, let handle else { return }
        store.discardOutgoingMessage(handle)
    }

    private func settle(_ state: FirstMateOutgoingMessage.State?) -> Bool {
        if state?.isAcceptedAwaitingSnapshot == true {
            isAccepted = true
            error = nil
            return true
        }
        error = handle.flatMap { store.outgoingMessage($0)?.failureMessage }
            ?? "Delivery could not be confirmed. Your words are kept here."
        return false
    }
}
