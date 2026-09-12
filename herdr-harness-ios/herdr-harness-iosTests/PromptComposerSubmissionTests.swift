import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Prompt composer submission capture")
struct PromptComposerSubmissionTests {
    @MainActor
    @Test("Sendable draft text keeps exact whitespace")
    func exactDraftText() {
        let draft = "\n  indented request\n"

        #expect(
            PromptComposerView.submissionMessage(
                draft: draft,
                uploadedPaths: [],
                containsDictation: false
            ) == draft
        )
    }

    @MainActor
    @Test("Whitespace-only text gates out without normalizing an attachment submission")
    func whitespaceOnlyDraft() {
        #expect(
            PromptComposerView.submissionMessage(
                draft: " \n  ",
                uploadedPaths: ["/synthetic/context.txt"],
                containsDictation: false
            ) == "Attachment: `/synthetic/context.txt`"
        )
    }

    @MainActor
    @Test("Successful completion removes only attachments captured by that submission")
    func attachmentCompletionDoesNotClearLaterState() {
        let submitted = attachment(status: .uploaded, path: "/synthetic/submitted.txt")
        let failed = attachment(status: .failed, path: nil)
        let addedLater = attachment(status: .uploaded, path: "/synthetic/later.txt")
        let captured = PromptComposerView.submittedAttachments(from: [submitted, failed])

        let remaining = PromptComposerView.remainingAttachments(
            afterRemoving: Set(captured.map(\.id)),
            from: [submitted, failed, addedLater]
        )

        #expect(captured.map(\.id) == [submitted.id])
        #expect(remaining.map(\.id) == [failed.id, addedLater.id])
    }

    private func attachment(status: TerminalAttachmentStatus, path: String?) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: "synthetic.txt",
            sourceURL: URL(fileURLWithPath: "/tmp/herdr-synthetic.txt"),
            byteCount: 10,
            sourceOwnership: .userSelected,
            status: status,
            uploaded: path.map {
                UploadedAttachment(
                    id: UUID().uuidString,
                    filename: "synthetic.txt",
                    originalFilename: "synthetic.txt",
                    contentType: "text/plain",
                    size: 10,
                    path: $0,
                    workspaceID: "synthetic-workspace",
                    createdAt: "2030-01-01T00:00:00Z"
                )
            },
            error: status == .failed ? "Synthetic failure" : nil
        )
    }
}
