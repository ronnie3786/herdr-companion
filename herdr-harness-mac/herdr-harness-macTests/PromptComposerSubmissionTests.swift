import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Shared prompt composer submission")
struct PromptComposerSubmissionTests {
    @Test("A selected failed or uploading attachment blocks every send")
    func unreadyAttachmentBlocksSend() {
        let failed = attachment(status: .failed, uploaded: nil)
        let uploading = attachment(status: .uploading, uploaded: nil)
        #expect(!PromptComposerSubmission.isReady(
            draft: "Send this",
            attachments: [failed],
            quoteCount: 0,
            conversationReferenceCount: 0,
            isSubmitting: false,
            canControl: true,
            dispositionIsAvailable: true
        ))
        #expect(!PromptComposerSubmission.isReady(
            draft: "",
            attachments: [uploading],
            quoteCount: 1,
            conversationReferenceCount: 0,
            isSubmitting: false,
            canControl: true,
            dispositionIsAvailable: true
        ))
    }

    @Test("Attachment-only and quote-only submissions remain valid")
    func nonTextSubmissions() {
        let uploaded = attachment(status: .uploaded, uploaded: uploadedAttachment)
        #expect(PromptComposerSubmission.isReady(
            draft: "",
            attachments: [uploaded],
            quoteCount: 0,
            conversationReferenceCount: 0,
            isSubmitting: false,
            canControl: true,
            dispositionIsAvailable: true
        ))
        #expect(PromptComposerSubmission.isReady(
            draft: "",
            attachments: [],
            quoteCount: 1,
            conversationReferenceCount: 0,
            isSubmitting: false,
            canControl: true,
            dispositionIsAvailable: true
        ))
    }

    @Test("Late accepted sends consume exact sent items without clearing newer edits or dictation")
    func acceptedCompletion() {
        let sentAttachment = attachment(status: .uploaded, uploaded: uploadedAttachment)
        let newerAttachment = attachment(status: .uploaded, uploaded: uploadedAttachment)
        let sentQuote = ChatQuote(text: "Sent", comment: "Use this", source: "Synthetic")
        let newerQuote = ChatQuote(text: "New", comment: "Keep this", source: "Synthetic")
        var draft = "A newer edit after the request started"
        var attachments = [sentAttachment, newerAttachment]
        var quotes = [sentQuote, newerQuote]
        var containsDictation = true
        PromptComposerSubmission.consumeAccepted(
            sentDraft: "Original transcribed direction",
            sentAttachmentIDs: [sentAttachment.id],
            sentQuoteIDs: [sentQuote.id],
            sentContainsDictation: true,
            draft: &draft,
            attachments: &attachments,
            quotes: &quotes,
            containsDictation: &containsDictation
        )
        #expect(draft == "A newer edit after the request started")
        #expect(attachments.map(\.id) == [newerAttachment.id])
        #expect(quotes.map(\.id) == [newerQuote.id])
        #expect(containsDictation)

        draft = "Original transcribed direction"
        PromptComposerSubmission.consumeAccepted(
            sentDraft: draft,
            sentAttachmentIDs: [],
            sentQuoteIDs: [],
            sentContainsDictation: true,
            draft: &draft,
            attachments: &attachments,
            quotes: &quotes,
            containsDictation: &containsDictation
        )
        #expect(draft.isEmpty)
        #expect(!containsDictation)
    }

    @Test("Deferred upload completion updates the original staged item")
    func deferredUploadCompletion() {
        let uploading = attachment(status: .uploading, uploaded: nil)
        let other = attachment(status: .failed, uploaded: nil)
        let updated = PromptComposerSubmission.applyingUploadSuccess(
            uploadedAttachment,
            itemID: uploading.id,
            to: [uploading, other]
        )
        #expect(updated[0].status == .uploaded)
        #expect(updated[0].uploadedPath == uploadedAttachment.path)
        #expect(updated[1].status == .failed)
    }

    @Test("Quotes and files share deterministic inline serialization")
    func serialization() throws {
        let quoteID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let quote = ChatQuote(
            id: quoteID,
            text: "Keep this response",
            comment: "Use it in the plan",
            source: "First Mate feature synthetic-feature · message synthetic-message"
        )
        let payload = PromptComposerSubmission.payload(
            draft: "Proceed",
            attachments: [attachment(status: .uploaded, uploaded: uploadedAttachment)],
            quotes: [quote],
            references: [],
            containsDictation: false
        )
        #expect(payload.contains("Quoted response segments:"))
        #expect(payload.contains("> Keep this response"))
        #expect(payload.contains("User’s message: Use it in the plan"))
        #expect(payload.hasSuffix("Attachment: `first-mate:synthetic-feature/attachment-1`"))
    }

    private var uploadedAttachment: UploadedAttachment {
        UploadedAttachment(
            id: "attachment-1",
            filename: "sample.txt",
            originalFilename: "Sample.txt",
            contentType: "text/plain",
            size: 12,
            path: "first-mate:synthetic-feature/attachment-1",
            workspaceID: "first-mate:synthetic-feature",
            createdAt: "2030-01-01T12:00:00Z"
        )
    }

    private func attachment(
        status: TerminalAttachmentStatus,
        uploaded: UploadedAttachment?
    ) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: "sample.txt",
            sourceURL: URL(fileURLWithPath: "/tmp/herdr-synthetic-sample.txt"),
            byteCount: 12,
            sourceOwnership: .userSelected,
            status: status,
            uploaded: uploaded,
            error: status == .failed ? "Synthetic upload failure" : nil
        )
    }
}
