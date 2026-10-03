import Foundation
import Observation

/// In-memory staged Mac composer material, scoped to one `FirstMateStore`
/// lifetime and separated by exact feature identity.
@MainActor @Observable
final class FirstMateComposerDraftStore {
    private var attachmentsByFeature: [String: [TerminalAttachment]] = [:]
    private var quotesByFeature: [String: [ChatQuote]] = [:]
    private var dictationByFeature: [String: Bool] = [:]
    private var editsByFeature: [String: Int] = [:]
    private var textEditsByFeature: [String: Int] = [:]
    private struct Frozen {
        let handle: FirstMateOutgoingMessage.Handle
        let submission: FirstMateOutgoingMessage.Submission
        let attachments: [TerminalAttachment]
        let quotes: [ChatQuote]
        var detachedRevision: Int?
        var restoredRevision: Int?
    }
    private var frozen: [String: Frozen] = [:]

    func noteDraftEdit(for featureID: String) {
        textEditsByFeature[featureID, default: 0] &+= 1
        noteEdit(for: featureID)
    }
    func revision(for featureID: String) -> Int { textEditsByFeature[featureID, default: 0] }

    private func noteEdit(for featureID: String) {
        editsByFeature[featureID, default: 0] &+= 1
    }

    func freeze(_ handle: FirstMateOutgoingMessage.Handle, submission: FirstMateOutgoingMessage.Submission,
                attachments: [TerminalAttachment], quotes: [ChatQuote]) {
        frozen[handle.outgoingID] = Frozen(handle: handle, submission: submission,
                                           attachments: attachments, quotes: quotes)
    }

    func didDetach(_ handle: FirstMateOutgoingMessage.Handle) {
        frozen[handle.outgoingID]?.detachedRevision = editsByFeature[handle.featureID, default: 0]
    }

    /// Restore only if no edit (including an identical replacement) followed
    /// detachment. A later draft is never overwritten by a late failure.
    func settle(_ handle: FirstMateOutgoingMessage.Handle, accepted: Bool, store: FirstMateStore) {
        guard var record = frozen[handle.outgoingID], record.handle == handle,
              store.outgoingMessage(handle) != nil else { return }
        if accepted {
            frozen[handle.outgoingID] = nil
            return
        }
        guard let revision = record.detachedRevision,
              editsByFeature[handle.featureID, default: 0] == revision,
              store.composerDraft(for: handle.context).isEmpty,
              attachments(for: handle.featureID).isEmpty,
              quotes(for: handle.featureID).isEmpty else { return }
        restore(record, store: store)
        record.restoredRevision = editsByFeature[handle.featureID, default: 0]
        frozen[handle.outgoingID] = record
    }

    /// Retain the failed row and original request identity; retry is explicit.
    /// A restored draft is detached only if it has not been touched since.
    func prepareRetry(_ handle: FirstMateOutgoingMessage.Handle, store: FirstMateStore) {
        guard let record = frozen[handle.outgoingID], record.handle == handle,
              let revision = record.restoredRevision,
              editsByFeature[handle.featureID, default: 0] == revision else { return }
        store.setComposerDraft("", for: handle.context)
        noteDraftEdit(for: handle.featureID)
        setAttachments([], for: handle.featureID)
        setQuotes([], for: handle.featureID)
        setContainsDictation(false, for: handle.featureID)
        didDetach(handle)
    }

    /// Recovery when another draft was typed: never overwrite it. The frozen
    /// payload stays in the error row for Copy and explicit retry instead.
    private func restore(_ record: Frozen, store: FirstMateStore) {
        let featureID = record.handle.featureID
        store.setComposerDraft(record.submission.draft, for: record.handle.context)
        noteDraftEdit(for: featureID)
        setAttachments(record.attachments, for: featureID)
        setQuotes(record.quotes, for: featureID)
        setContainsDictation(record.submission.containsDictation, for: featureID)
    }

    var hasStagedContent: Bool {
        attachmentsByFeature.values.contains { !$0.isEmpty }
            || quotesByFeature.values.contains { !$0.isEmpty }
    }

    func attachments(for featureID: String) -> [TerminalAttachment] {
        attachmentsByFeature[featureID] ?? []
    }

    func setAttachments(_ attachments: [TerminalAttachment], for featureID: String) {
        attachmentsByFeature[featureID] = attachments.isEmpty ? nil : attachments
        noteEdit(for: featureID)
    }

    func quotes(for featureID: String) -> [ChatQuote] {
        quotesByFeature[featureID] ?? []
    }

    func setQuotes(_ quotes: [ChatQuote], for featureID: String) {
        quotesByFeature[featureID] = quotes.isEmpty ? nil : quotes
        noteEdit(for: featureID)
    }

    func containsDictation(for featureID: String) -> Bool {
        dictationByFeature[featureID] ?? false
    }

    func setContainsDictation(_ containsDictation: Bool, for featureID: String) {
        dictationByFeature[featureID] = containsDictation ? true : nil
        noteEdit(for: featureID)
    }

    func discardAll() {
        (attachmentsByFeature.values.flatMap { $0 } + frozen.values.flatMap(\.attachments))
            .forEach { $0.removeSourceFileIfOwned() }
        attachmentsByFeature = [:]
        quotesByFeature = [:]
        dictationByFeature = [:]
        editsByFeature = [:]
        textEditsByFeature = [:]
        frozen = [:]
    }
}
