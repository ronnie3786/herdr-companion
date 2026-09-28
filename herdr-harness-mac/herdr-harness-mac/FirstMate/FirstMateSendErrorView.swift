import AppKit
import SwiftUI

/// Send failures are separate from refresh notices and remain visible until
/// explicitly retried or until this store's connection lifecycle ends.
struct FirstMateSendErrorView: View {
    @Bindable var store: FirstMateStore
    let featureID: String

    var body: some View {
        if let failure = store.sendFailure(for: featureID), let message = failure.failureMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.presentationStatus == "failed" ? "Message not sent: \(message)" : message)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("first-mate-send-error")
                    HStack(spacing: 12) {
                        Button("Retry send") { retry(failure) }
                            .disabled(store.isSending || store.isSubmitting(featureID: featureID) || !store.controlAvailable
                                || ["completed", "cancelled"].contains(store.snapshots[featureID]?.feature.status ?? ""))
                            .accessibilityIdentifier("first-mate-retry-send")
                        Button("Copy failed message") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(failure.text, forType: .string)
                        }
                        .accessibilityIdentifier("first-mate-copy-failed-send")
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .herdrFont(size: HerdrTheme.TextSize.small)
            .foregroundStyle(HerdrTheme.alert)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)
        }
    }

    private func retry(_ failure: FirstMateOutgoingMessage) {
        let context = store.operationContext
        guard context.matchesFeature(featureID), store.isDestinationAlive(context),
              !["completed", "cancelled"].contains(store.snapshots[featureID]?.feature.status ?? ""),
              !store.isSending, !store.isSubmitting(featureID: featureID), store.controlAvailable else { return }
        let handle = FirstMateOutgoingMessage.Handle(
            outgoingID: failure.id, requestID: failure.requestID,
            featureID: featureID, context: context
        )
        guard store.outgoingMessage(handle)?.state.isRetryable == true else { return }
        store.composerDrafts.prepareRetry(handle, store: store)
        Task {
            guard let state = await store.retryOutgoingMessage(handle) else { return }
            let accepted = state.isAcceptedAwaitingSnapshot
            store.composerDrafts.settle(handle, accepted: accepted, store: store)
            if accepted { await store.refreshFeature(context) }
        }
    }
}
