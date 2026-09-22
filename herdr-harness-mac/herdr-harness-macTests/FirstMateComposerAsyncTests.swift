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
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?
    var uploadIsWaiting: Bool { uploadContinuation != nil }
    var sendIsWaiting: Bool { sendContinuation != nil }

    func releaseUpload() { uploadContinuation?.resume(); uploadContinuation = nil }
    func releaseSend() { sendContinuation?.resume(); sendContinuation = nil }

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
        await withCheckedContinuation { uploadContinuation = $0 }
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
        await withCheckedContinuation { sendContinuation = $0 }
        return try #require(FirstMateDemo.features(step: 0).first { $0.feature.id == featureID })
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
