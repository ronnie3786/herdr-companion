import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate production optimistic composer", .serialized)
@MainActor
struct FirstMateOptimisticComposerTests {
    @Test("The production binding clears and projects the outgoing row before the POST completes")
    func pendingThenAccepted() async throws {
        let fixture = try await Fixture()
        let task = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        #expect(fixture.store.composerDraft(for: fixture.context).isEmpty)
        let busyComposer = fixture.composer.productionView
        #expect(busyComposer.destination.isSubmitting)
        #expect(!busyComposer.blocksEditingWhileSubmitting)
        let messages = FirstMateTranscriptLayout.orderedMessages(store: fixture.store, snapshot: fixture.snapshot)
        #expect(messages.last?.role == "user")
        #expect(messages.last?.text == "Synthetic direction")
        #expect(messages.last?.status == "sending")
        #expect(FirstMateTranscriptLayout.isAwaitingReply(store: fixture.store, snapshot: fixture.snapshot))
        #expect(FirstMateTranscriptLayout.rows(for: messages, typing: true, now: .now, calendar: .current).last?.speaker == .user)
        // A double Enter while the transport is suspended is not a second send.
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        await fixture.client.resolve(.success(fixture.snapshot))
        #expect(await task.value)
        #expect(fixture.store.composerDraft(for: fixture.context).isEmpty)
        #expect(fixture.store.outgoingMessages(for: fixture.snapshot.feature.id).count == 1)
        #expect(await fixture.client.requests.count == 1)
    }

    @Test("Rejected send restores untouched text, quote, attachment, and voice marker; retry is explicit")
    func rejectedAndRetry() async throws {
        let fixture = try await Fixture()
        let quote = ChatQuote(text: "Synthetic reply", comment: "Consider it", source: "Fixture")
        fixture.store.composerDrafts.setQuotes([quote], for: fixture.snapshot.feature.id)
        fixture.store.composerDrafts.setContainsDictation(true, for: fixture.snapshot.feature.id)
        let item = Self.attachment()
        fixture.store.composerDrafts.setAttachments([item], for: fixture.snapshot.feature.id)
        let task = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        #expect(fixture.store.composerDrafts.quotes(for: fixture.snapshot.feature.id).isEmpty)
        #expect(fixture.store.composerDrafts.attachments(for: fixture.snapshot.feature.id).isEmpty)
        await fixture.client.resolve(.failure(APIError.server(status: 401, message: "Synthetic authentication rejected")))
        #expect(!(await task.value))
        #expect(fixture.store.composerDraft(for: fixture.context) == "Synthetic direction")
        #expect(fixture.store.composerDrafts.quotes(for: fixture.snapshot.feature.id) == [quote])
        #expect(fixture.store.composerDrafts.attachments(for: fixture.snapshot.feature.id).map(\.id) == [item.id])
        #expect(fixture.store.composerDrafts.containsDictation(for: fixture.snapshot.feature.id))
        #expect(!FirstMateTranscriptLayout.isAwaitingReply(store: fixture.store, snapshot: fixture.snapshot))
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id) != nil)
        await fixture.store.refreshFeature(fixture.context)
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id) != nil)
        // Return on the restored payload cannot allocate a different request
        // identity; the visible retry is the only way to repeat it.
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        #expect(await fixture.client.requests.count == 1)
        let failure = try #require(fixture.store.sendFailure(for: fixture.snapshot.feature.id))
        let handle = FirstMateOutgoingMessage.Handle(outgoingID: failure.id, requestID: failure.requestID,
                                                      featureID: failure.featureID, context: fixture.context)
        fixture.store.composerDrafts.prepareRetry(handle, store: fixture.store)
        let retry = Task { await fixture.store.retryOutgoingMessage(handle) }
        try await fixture.waitForSend(count: 2)
        #expect(fixture.store.composerDraft(for: fixture.context).isEmpty)
        await fixture.client.resolve(.success(fixture.snapshot))
        let result = await retry.value
        #expect(result?.isAcceptedAwaitingSnapshot == true)
        fixture.store.composerDrafts.settle(handle, accepted: true, store: fixture.store)
        #expect(await Set(fixture.client.requests.map(\.requestID)).count == 1)
    }

    @Test("An identical newer edit survives acceptance, and a changed draft survives a connection loss")
    func newerEdits() async throws {
        let fixture = try await Fixture()
        let first = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        // The identical string is a NEW draft; acceptance must never clear it.
        fixture.store.setComposerDraft("Synthetic direction", for: fixture.context)
        fixture.store.composerDrafts.noteDraftEdit(for: fixture.snapshot.feature.id)
        let newAttachment = Self.attachment()
        fixture.store.composerDrafts.setAttachments([newAttachment], for: fixture.snapshot.feature.id)
        await fixture.client.resolve(.success(fixture.snapshot))
        #expect(await first.value)
        #expect(fixture.store.composerDraft(for: fixture.context) == "Synthetic direction")
        #expect(fixture.store.composerDrafts.attachments(for: fixture.snapshot.feature.id).map(\.id) == [newAttachment.id])
        let second = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend(count: 2)
        fixture.store.setComposerDraft("Newer work", for: fixture.context)
        fixture.store.composerDrafts.noteDraftEdit(for: fixture.snapshot.feature.id)
        let newQuote = ChatQuote(text: "New reply", comment: "Keep it", source: "Fixture")
        fixture.store.composerDrafts.setQuotes([newQuote], for: fixture.snapshot.feature.id)
        await fixture.client.resolve(.failure(APIError.server(status: 503, message: "Synthetic connection lost")))
        #expect(!(await second.value))
        #expect(fixture.store.composerDraft(for: fixture.context) == "Newer work")
        #expect(fixture.store.composerDrafts.quotes(for: fixture.snapshot.feature.id) == [newQuote])
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id)?.failureMessage?.contains("could not be confirmed") == true)
    }

    @Test("An identical new draft is not mistaken for an untouched failed composer")
    func identicalNewerDraftAfterFailure() async throws {
        let fixture = try await Fixture()
        let submittedQuote = ChatQuote(text: "Submitted", comment: "Frozen", source: "Fixture")
        fixture.store.composerDrafts.setQuotes([submittedQuote], for: fixture.snapshot.feature.id)
        let task = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        fixture.store.setComposerDraft("Synthetic direction", for: fixture.context)
        fixture.store.composerDrafts.noteDraftEdit(for: fixture.snapshot.feature.id)
        await fixture.client.resolve(.failure(APIError.server(status: 401, message: "Synthetic rejection")))
        #expect(!(await task.value))
        #expect(fixture.store.composerDraft(for: fixture.context) == "Synthetic direction")
        #expect(fixture.store.composerDrafts.quotes(for: fixture.snapshot.feature.id).isEmpty)
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id)?.text.contains("Quoted response segments:") == true)
    }

    @Test("A late rejection restores only its original feature, not the newly selected feature")
    func featureSwitchDuringSend() async throws {
        let fixture = try await Fixture()
        let second = try #require(FirstMateDemo.features(step: 0).first { $0.feature.id != fixture.snapshot.feature.id })
        fixture.store.receive(second)
        let task = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        fixture.store.select(second.feature.id)
        fixture.store.setComposerDraft("Other feature's draft", for: fixture.store.operationContext)
        await fixture.client.resolve(.failure(APIError.server(status: 403, message: "Synthetic rejection")))
        #expect(!(await task.value))
        #expect(fixture.store.draft == "Other feature's draft")
        #expect(fixture.store.composerDraft(for: fixture.context) == "Synthetic direction")
        #expect(fixture.store.sendFailure(for: second.feature.id) == nil)
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id) != nil)
    }

    @Test("Independent stores on the same feature ID never share drafts or outgoing rows")
    func independentWindows() async throws {
        let first = try await Fixture()
        let second = try await Fixture()
        #expect(first.snapshot.feature.id == second.snapshot.feature.id)
        let sending = Task { await first.composer.productionView.dispatchSubmission() }
        try await first.waitForSend()
        #expect(second.store.composerDraft(for: second.context) == "Synthetic direction")
        #expect(second.store.outgoingMessages(for: second.snapshot.feature.id).isEmpty)
        await first.client.resolve(.success(first.snapshot))
        #expect(await sending.value)
        #expect(second.store.composerDraft(for: second.context) == "Synthetic direction")
    }

    @Test("Reconnect fences the late response and the previously frozen draft")
    func reconnectDuringSend() async throws {
        let fixture = try await Fixture()
        let sending = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await fixture.waitForSend()
        fixture.store.configure(client: nil, demo: true)
        await fixture.client.resolve(.failure(APIError.invalidResponse))
        #expect(!(await sending.value))
        #expect(fixture.store.sendFailure(for: fixture.snapshot.feature.id) == nil)
        #expect(fixture.store.composerDrafts.quotes(for: fixture.snapshot.feature.id).isEmpty)
    }

    @Test("Unready and stale destinations do not reserve or consume a draft")
    func blockedAndSwitched() async throws {
        let fixture = try await Fixture()
        fixture.store.composerDrafts.setAttachments([Self.attachment(status: .uploading)], for: fixture.snapshot.feature.id)
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        #expect(fixture.store.outgoingMessages(for: fixture.snapshot.feature.id).isEmpty)
        fixture.store.composerDrafts.setAttachments([], for: fixture.snapshot.feature.id)
        let next = try #require(FirstMateDemo.features(step: 0).first { $0.feature.id != fixture.snapshot.feature.id })
        fixture.store.receive(next)
        fixture.store.select(next.feature.id)
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        #expect(fixture.store.composerDraft(for: fixture.context) == "Synthetic direction")
    }

    private static func attachment(status: TerminalAttachmentStatus = .uploaded) -> TerminalAttachment {
        TerminalAttachment(id: UUID(), filename: "synthetic.txt",
                           sourceURL: URL(fileURLWithPath: "/tmp/herdr-synthetic.txt"), byteCount: 4,
                           sourceOwnership: .userSelected, status: status,
                           uploaded: status == .uploaded ? UploadedAttachment(
                               id: "synthetic-upload", filename: "synthetic.txt", originalFilename: "synthetic.txt",
                               contentType: "text/plain", size: 4, path: "first-mate:synthetic/upload",
                               workspaceID: "first-mate:synthetic", createdAt: "2030-01-01T12:00:00Z") : nil,
                           error: nil)
    }

    @MainActor private final class Fixture {
        let client = DeferredClient()
        let store = FirstMateStore()
        let model = ChatFixtures.model(demo: true)
        let snapshot: FirstMateSnapshot
        let context: FirstMateStore.OperationContext
        let composer: FirstMatePromptComposer

        init() async throws {
            store.configure(client: client, demo: false)
            await store.refresh()
            _ = store.acquireControlLease(available: true)
            context = store.operationContext
            snapshot = try #require(store.snapshot(for: context))
            store.setComposerDraft("Synthetic direction", for: context)
            composer = FirstMatePromptComposer(store: store, model: model, snapshot: snapshot,
                                               canControl: true, modelFavorites: ModelFavoritesStore())
        }

        func waitForSend(count: Int = 1) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while await client.requests.count < count {
                guard clock.now < deadline else { throw APIError.invalidResponse }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

actor DeferredClient: FirstMateClient {
    struct Request: Sendable { let featureID: String; let text: String; let requestID: String }
    private(set) var requests: [Request] = []
    private var continuation: CheckedContinuation<FirstMateSnapshot, Error>?

    func resolve(_ result: Result<FirstMateSnapshot, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-attachments-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: FirstMateDemo.features(step: 0).map(\.feature))
    }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures()
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        try #require(FirstMateDemo.features(step: 0).first { $0.feature.id == id })
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        requests.append(Request(featureID: featureID, text: text, requestID: requestID))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
