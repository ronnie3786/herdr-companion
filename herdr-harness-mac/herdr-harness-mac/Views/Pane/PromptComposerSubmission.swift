import Foundation

enum PromptComposerSubmission {
    static func isReady(
        draft: String,
        attachments: [TerminalAttachment],
        quoteCount: Int,
        conversationReferenceCount: Int,
        isSubmitting: Bool,
        canControl: Bool,
        dispositionIsAvailable: Bool
    ) -> Bool {
        hasReadyContent(
            draft: draft,
            attachments: attachments,
            quoteCount: quoteCount,
            conversationReferenceCount: conversationReferenceCount
        )
            && !isSubmitting
            && canControl
            && dispositionIsAvailable
    }

    /// The staged-content half of readiness, independent of the destination's
    /// control and submission state. Asynchronous completions pair this with
    /// `PromptComposerDestination.isReadyToSubmit` so a completion that resumes
    /// after a suspension never trusts the view snapshot that started it.
    static func hasReadyContent(
        draft: String,
        attachments: [TerminalAttachment],
        quoteCount: Int,
        conversationReferenceCount: Int
    ) -> Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUploadedAttachment = attachments.contains {
            $0.status == .uploaded && $0.uploadedPath != nil
        }
        let hasUnreadyAttachment = attachments.contains {
            $0.status == .uploading || $0.status == .failed
        }
        return (hasText || hasUploadedAttachment || quoteCount > 0 || conversationReferenceCount > 0)
            && !hasUnreadyAttachment
    }

    static func applyingUploadSuccess(
        _ uploaded: UploadedAttachment,
        itemID: UUID,
        to attachments: [TerminalAttachment]
    ) -> [TerminalAttachment] {
        var updated = attachments
        guard let index = updated.firstIndex(where: { $0.id == itemID }) else { return updated }
        updated[index].uploaded = uploaded
        updated[index].error = nil
        updated[index].status = .uploaded
        return updated
    }

    static func applyingUploadFailure(
        _ message: String,
        itemID: UUID,
        to attachments: [TerminalAttachment]
    ) -> [TerminalAttachment] {
        var updated = attachments
        guard let index = updated.firstIndex(where: { $0.id == itemID }) else { return updated }
        updated[index].error = message
        updated[index].status = .failed
        return updated
    }

    static func consumeAccepted(
        sentDraft: String,
        sentAttachmentIDs: Set<UUID>,
        sentQuoteIDs: Set<UUID>,
        sentContainsDictation: Bool,
        draft: inout String,
        attachments: inout [TerminalAttachment],
        quotes: inout [ChatQuote],
        containsDictation: inout Bool
    ) {
        if draft == sentDraft {
            draft = ""
            if sentContainsDictation { containsDictation = false }
        }
        attachments.removeAll { sentAttachmentIDs.contains($0.id) }
        quotes.removeAll { sentQuoteIDs.contains($0.id) }
    }

    static func payload(
        draft: String,
        attachments: [TerminalAttachment],
        quotes: [ChatQuote],
        references: [ConversationContextReference],
        containsDictation: Bool
    ) -> String {
        let quotedText = ChatQuote.prompt(
            draft.trimmingCharacters(in: .whitespacesAndNewlines),
            quotes: quotes
        )
        let attachmentBlock = attachments.compactMap(\.uploadedPath)
            .map { "Attachment: `\($0)`" }
            .joined(separator: "\n")
        var message = [quotedText, attachmentBlock]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if containsDictation, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\n(transcribed audio, please account for incorrect names or typos)"
        }
        return ConversationContextReference.prompt(currentRequest: message, references: references)
    }
}
