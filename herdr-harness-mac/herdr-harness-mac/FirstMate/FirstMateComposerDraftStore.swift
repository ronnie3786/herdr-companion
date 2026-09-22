import Foundation
import Observation

/// In-memory staged Mac composer material, scoped to one `FirstMateStore`
/// lifetime and separated by exact feature identity.
@MainActor @Observable
final class FirstMateComposerDraftStore {
    private var attachmentsByFeature: [String: [TerminalAttachment]] = [:]
    private var quotesByFeature: [String: [ChatQuote]] = [:]
    private var dictationByFeature: [String: Bool] = [:]

    var hasStagedContent: Bool {
        attachmentsByFeature.values.contains { !$0.isEmpty }
            || quotesByFeature.values.contains { !$0.isEmpty }
    }

    func attachments(for featureID: String) -> [TerminalAttachment] {
        attachmentsByFeature[featureID] ?? []
    }

    func setAttachments(_ attachments: [TerminalAttachment], for featureID: String) {
        attachmentsByFeature[featureID] = attachments.isEmpty ? nil : attachments
    }

    func quotes(for featureID: String) -> [ChatQuote] {
        quotesByFeature[featureID] ?? []
    }

    func setQuotes(_ quotes: [ChatQuote], for featureID: String) {
        quotesByFeature[featureID] = quotes.isEmpty ? nil : quotes
    }

    func containsDictation(for featureID: String) -> Bool {
        dictationByFeature[featureID] ?? false
    }

    func setContainsDictation(_ containsDictation: Bool, for featureID: String) {
        dictationByFeature[featureID] = containsDictation ? true : nil
    }

    func discardAll() {
        attachmentsByFeature.values.joined().forEach { $0.removeSourceFileIfOwned() }
        attachmentsByFeature = [:]
        quotesByFeature = [:]
        dictationByFeature = [:]
    }
}
