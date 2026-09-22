import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate deferred composer operations", .serialized)
@MainActor
struct FirstMateComposerAsyncTests {
    @Test("Upload completion follows its original feature after selection changes")
    func uploadAfterSelectionChange() async throws {
        let client = DeferredFirstMateComposerClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let firstID = try #require(store.selectedFeatureID)
        let second = FirstMateDemo.features(step: 0)[1]
        store.receive(second)
        let context = store.operationContext
        let item = attachment(status: .uploading)
        store.composerDrafts.setAttachments([item], for: firstID)

        let upload = Task {
            try await store.uploadAttachment(
                at: item.sourceURL,
                contentType: "text/plain",
                expectedContext: context
            )
        }
        do {
            try await waitUntil("upload request to suspend") { await client.uploadIsWaiting }
        } catch {
            upload.cancel()
            await client.releaseUpload()
            _ = try? await upload.value
            throw error
        }
        store.select(second.feature.id)
        await client.releaseUpload()
        let uploaded = try await upload.value
        let updated = PromptComposerSubmission.applyingUploadSuccess(
            uploaded,
            itemID: item.id,
            to: store.composerDrafts.attachments(for: firstID)
        )
        store.composerDrafts.setAttachments(updated, for: firstID)

        #expect(store.composerDrafts.attachments(for: firstID).first?.status == .uploaded)
        #expect(store.composerDrafts.attachments(for: second.feature.id).isEmpty)
    }

    @Test("Accepted send after a switch clears only the original accepted material")
    func sendAfterSelectionChange() async throws {
        let client = DeferredFirstMateComposerClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let firstID = try #require(store.selectedFeatureID)
        let second = FirstMateDemo.features(step: 0)[1]
        store.receive(second)
        let context = store.operationContext
        store.setComposerDraft("Original transcribed direction", for: context)
        store.composerDrafts.setContainsDictation(true, for: firstID)
        let quote = ChatQuote(text: "Synthetic answer", comment: "Use it", source: "Synthetic")
        store.composerDrafts.setQuotes([quote], for: firstID)

        let sending = Task {
            await store.sendPreparedMessage("Original transcribed direction", expectedContext: context)
        }
        do {
            try await waitUntil("send request to suspend") { await client.sendIsWaiting }
        } catch {
            sending.cancel()
            await client.releaseSend()
            _ = await sending.value
            throw error
        }
        store.select(second.feature.id)
        store.setComposerDraft("Newer second-feature edit", for: store.operationContext)
        await client.releaseSend()
        #expect(await sending.value)

        var originalDraft = store.composerDraft(for: context)
        var originalAttachments = store.composerDrafts.attachments(for: firstID)
        var originalQuotes = store.composerDrafts.quotes(for: firstID)
        var originalDictation = store.composerDrafts.containsDictation(for: firstID)
        PromptComposerSubmission.consumeAccepted(
            sentDraft: "Original transcribed direction",
            sentAttachmentIDs: [],
            sentQuoteIDs: [quote.id],
            sentContainsDictation: true,
            draft: &originalDraft,
            attachments: &originalAttachments,
            quotes: &originalQuotes,
            containsDictation: &originalDictation
        )
        store.setComposerDraft(originalDraft, for: context)
        store.composerDrafts.setQuotes(originalQuotes, for: firstID)
        store.composerDrafts.setContainsDictation(originalDictation, for: firstID)

        #expect(store.composerDraft(for: context).isEmpty)
        #expect(store.composerDrafts.quotes(for: firstID).isEmpty)
        #expect(!store.composerDrafts.containsDictation(for: firstID))
        #expect(store.draft == "Newer second-feature edit")
    }

    @Test("Reconnect fences a late send response")
    func reconnectInvalidatesSend() async throws {
        let client = DeferredFirstMateComposerClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let context = store.operationContext
        let sending = Task { await store.sendPreparedMessage("Do not land after reconnect", expectedContext: context) }
        do {
            try await waitUntil("send request to suspend") { await client.sendIsWaiting }
        } catch {
            sending.cancel()
            await client.releaseSend()
            _ = await sending.value
            throw error
        }
        store.configure(client: nil, demo: true)
        await client.releaseSend()
        #expect(!(await sending.value))
        #expect(!store.features.isEmpty)
        #expect(store.isDemo)
    }

    @Test("Cancellation and release before fake entry cannot strand continuations")
    func cancellationBeforeContinuationEntry() async throws {
        let client = DeferredFirstMateComposerClient(deferOperationEntry: true)
        let upload = Task {
            try await client.uploadFirstMateAttachment(
                featureID: "synthetic-feature",
                fileURL: URL(fileURLWithPath: "/tmp/herdr-first-mate-synthetic.txt"),
                contentType: "text/plain"
            )
        }
        let send = Task {
            try await client.sendFirstMateMessage(
                featureID: FirstMateDemo.features(step: 0)[0].feature.id,
                text: "Synthetic cancellation",
                requestID: "synthetic-cancelled-request"
            )
        }

        do {
            try await waitUntil("upload and send to pause before continuation entry") {
                let uploadIsWaiting = await client.uploadEntryIsWaiting
                let sendIsWaiting = await client.sendEntryIsWaiting
                return uploadIsWaiting && sendIsWaiting
            }
        } catch {
            upload.cancel()
            send.cancel()
            await client.releaseUpload()
            await client.releaseSend()
            throw error
        }

        upload.cancel()
        send.cancel()
        await client.releaseUpload()
        await client.releaseSend()
        do {
            try await waitUntil("cancelled upload and send to finish") {
                let uploadFinished = await client.uploadDidFinish
                let sendFinished = await client.sendDidFinish
                return uploadFinished && sendFinished
            }
        } catch {
            // A second release makes a regression fail boundedly rather than
            // leaving the test process parked on a checked continuation.
            await client.releaseUpload()
            await client.releaseSend()
            throw error
        }

        var uploadCancelled = false
        do { _ = try await upload.value } catch is CancellationError { uploadCancelled = true } catch {}
        var sendCancelled = false
        do { _ = try await send.value } catch is CancellationError { sendCancelled = true } catch {}
        #expect(uploadCancelled)
        #expect(sendCancelled)
    }

    private enum DeferredWaitError: Error {
        case timedOut(String)
    }

    private func waitUntil(
        _ description: String,
        condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw DeferredWaitError.timedOut(description) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func attachment(status: TerminalAttachmentStatus) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: "synthetic.txt",
            sourceURL: URL(fileURLWithPath: "/tmp/herdr-first-mate-synthetic.txt"),
            byteCount: 9,
            sourceOwnership: .userSelected,
            status: status,
            uploaded: nil,
            error: nil
        )
    }
}

private actor DeferredFirstMateComposerClient: FirstMateClient {
    private let deferOperationEntry: Bool
    private var uploadEntryContinuation: CheckedContinuation<Void, Never>?
    private var sendEntryContinuation: CheckedContinuation<Void, Never>?
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var uploadReleased = false
    private var sendReleased = false
    private(set) var uploadDidFinish = false
    private(set) var sendDidFinish = false

    init(deferOperationEntry: Bool = false) {
        self.deferOperationEntry = deferOperationEntry
    }

    var uploadEntryIsWaiting: Bool { uploadEntryContinuation != nil }
    var sendEntryIsWaiting: Bool { sendEntryContinuation != nil }
    var uploadIsWaiting: Bool { uploadContinuation != nil }
    var sendIsWaiting: Bool { sendContinuation != nil }

    func releaseUpload() {
        if let uploadContinuation {
            self.uploadContinuation = nil
            uploadContinuation.resume()
        } else {
            uploadReleased = true
        }
        uploadEntryContinuation?.resume()
        uploadEntryContinuation = nil
    }

    func releaseSend() {
        if let sendContinuation {
            self.sendContinuation = nil
            sendContinuation.resume()
        } else {
            sendReleased = true
        }
        sendEntryContinuation?.resume()
        sendEntryContinuation = nil
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-attachments-v1"])
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures(scope: .active)
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        .init(ok: true, features: FirstMateDemo.features(step: 0).map(\.feature))
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        try #require(FirstMateDemo.features(step: 0).first { $0.feature.id == id })
    }

    func uploadFirstMateAttachment(
        featureID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        defer { uploadDidFinish = true }
        if deferOperationEntry {
            await withCheckedContinuation { uploadEntryContinuation = $0 }
        }
        try Task.checkCancellation()
        if uploadReleased {
            uploadReleased = false
        } else {
            await withCheckedContinuation { uploadContinuation = $0 }
        }
        try Task.checkCancellation()
        return .init(ok: true, attachment: UploadedAttachment(
            id: "uploaded",
            filename: fileURL.lastPathComponent,
            originalFilename: fileURL.lastPathComponent,
            contentType: contentType,
            size: 9,
            path: "first-mate:\(featureID)/uploaded",
            workspaceID: "first-mate:\(featureID)",
            createdAt: "2030-01-01T12:00:00Z"
        ), error: nil)
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        defer { sendDidFinish = true }
        if deferOperationEntry {
            await withCheckedContinuation { sendEntryContinuation = $0 }
        }
        try Task.checkCancellation()
        if sendReleased {
            sendReleased = false
        } else {
            await withCheckedContinuation { sendContinuation = $0 }
        }
        try Task.checkCancellation()
        return try #require(FirstMateDemo.features(step: 0).first { $0.feature.id == featureID })
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
