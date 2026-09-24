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

    @MainActor
    @Test("A compaction in progress refuses submission without clearing the draft")
    func compactionInProgressRefusesSubmission() async throws {
        let store = PiConversationStore()
        let pane = testPane()
        let drafts = PaneDraftStore()
        drafts.setText("unsent draft", for: pane.id)
        var submissions = 0
        store.submitProvider = { _, _, _ in submissions += 1 }

        let stream = AsyncThrowingStream<PiConversationStreamEvent, any Error> { continuation in
            continuation.yield(.envelope(try! envelope(
                1,
                #"{"type":"session_before_compact","reason":"manual","willRetry":false}"#
            )))
            continuation.finish()
        }
        #expect(!(try await store.consume(stream)))
        #expect(store.compactionActivity != nil)
        #expect(store.compactionCompletion == nil)

        let accepted = await store.submit(
            text: "unsent draft",
            disposition: .prompt,
            model: HerdrAppModel(arguments: []),
            pane: pane
        )

        #expect(!accepted)
        #expect(submissions == 0)
        #expect(drafts.text(for: pane.id) == "unsent draft")
    }

    @MainActor
    @Test("Completing a compaction neither submits nor clears an unsent draft")
    func completionDoesNotSubmitOrClearDraft() async throws {
        let store = PiConversationStore()
        let pane = testPane()
        let drafts = PaneDraftStore()
        drafts.setText("unsent draft", for: pane.id)
        var submissions = 0
        var streamContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        let (published, publishedContinuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in publishedContinuation.yield(()) }
        store.submitProvider = { _, _, _ in submissions += 1 }
        store.snapshotProvider = { _ in
            try JSONDecoder().decode(
                PiConversationSnapshot.self,
                from: Data(
                    #"{"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","available":true,"connected":true,"session":{"id":"s1"},"state":{"isStreaming":false,"context":{"tokens":1}},"entries":[{"type":"compaction","id":"compact-1","summary":"Synthetic summary"}],"pending_interactions":[],"cursor":"1","latest_cursor":"1","oldest_cursor":"0","truncated":false}"#.utf8
                )
            )
        }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { streamContinuation = $0 }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            streamContinuation?.finish()
            publishedContinuation.finish()
        }
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()
        #expect(store.compactionCompletion?.evidence == .entry("compact-1"))
        #expect(submissions == 0)
        #expect(drafts.text(for: pane.id) == "unsent draft")

        task.cancel()
        await task.value
    }

    private func testPane() -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }

    private func envelope(_ cursor: Int, _ json: String) throws -> PiConversationEnvelope {
        PiConversationEnvelope(
            paneID: "w1:p1",
            sessionID: "s1",
            cursor: String(cursor),
            event: try JSONDecoder().decode(PiJSONValue.self, from: Data(json.utf8))
        )
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
