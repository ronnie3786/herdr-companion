import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Coverage for the First Mate voice swap (issue #81):
///
/// - the external microphone dictates while the More voice entry opens the
///   unchanged recorder sheet, and every other destination keeps the previous
///   routing;
/// - an explicit Stop transcribes and submits a nonempty transcript exactly
///   once through the composer's normal submission path;
/// - repeated Stop affordances, delayed callbacks, automatic duration
///   completion, destination changes, and invalidation can never duplicate the
///   transcription or send a stale transcript.
///
/// `PromptComposerDictationSession` is the production orchestration under test;
/// `DictationComposerStub` supplies the destination-bound operations the real
/// `PromptComposerView` wires to its live bindings, and it uses the production
/// `PromptComposerSubmission` readiness, payload, and consumption helpers.
@Suite("First Mate voice composer", .serialized)
@MainActor
struct FirstMateVoiceComposerTests {
    // MARK: - Action routing

    @Test("The microphone and the More voice row swap roles for First Mate only")
    func policyRouting() {
        #expect(PromptComposerVoicePolicy.legacy.externalVoiceRole == .openRecorder)
        #expect(PromptComposerVoicePolicy.legacy.menuVoiceRole == .dictate)
        #expect(!PromptComposerVoicePolicy.legacy.submitsOnExplicitStop)

        #expect(PromptComposerVoicePolicy.firstMateStopToSend.externalVoiceRole == .dictate)
        #expect(PromptComposerVoicePolicy.firstMateStopToSend.menuVoiceRole == .openRecorder)
        #expect(PromptComposerVoicePolicy.firstMateStopToSend.submitsOnExplicitStop)
    }

    @Test("Destination equality distinguishes the voice policy")
    func destinationEquality() {
        let legacy = destination(policy: .legacy)
        let firstMate = destination(policy: .firstMateStopToSend)
        #expect(legacy != firstMate)
        #expect(legacy == destination(policy: .legacy))
    }

    // MARK: - Stop-to-submit

    @Test("An explicit Stop submits a nonempty transcript once, only after completion")
    func explicitStopSubmitsAfterTranscription() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.4
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }

        try await waitUntil("transcription to suspend") { transcriber.isWaiting }
        #expect(composer.submissions.isEmpty)
        #expect(!composer.draft.contains("Ship the fix"))

        transcriber.succeed(with: transcription("Ship the fix"))
        let outcome = await finishing.value

        #expect(outcome == .submitted(transcription("Ship the fix")))
        #expect(composer.submissions.count == 1)
        #expect(composer.submissions[0].contains("Existing direction"))
        #expect(composer.submissions[0].contains("Ship the fix"))
        #expect(composer.submissions[0].contains("(transcribed audio"))
        #expect(composer.draft.isEmpty)
        #expect(!composer.containsDictation)
        #expect(composer.reportedErrors.isEmpty)
    }

    @Test("The external microphone click starts and stops First Mate dictation through the session")
    func externalMicClickSubmits() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()

        // One click starts; the same control's next click records the
        // explicit-stop intent that authorizes the send.
        #expect(session.externalMicAction(canStart: true) == .start)
        #expect(session.phase == .locked)
        harness.engine?.currentTime = 1.3
        #expect(session.externalMicAction(canStart: true) == .stop)

        let outcome = await session.finish(composer.completion(transcribe: immediate("From the microphone")))
        #expect(outcome == .submitted(transcription("From the microphone")))
        #expect(composer.submissions.count == 1)
    }

    @Test("A click while unready still stops an active recording")
    func externalMicStopIgnoresReadiness() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.externalMicAction(canStart: true) == .start)
        harness.engine?.currentTime = 1.2
        // A pause or model-settings request now owns submission readiness. The
        // next microphone click is a Stop and must still end the capture.
        composer.isSubmitting = true
        #expect(session.externalMicAction(canStart: false) == .stop)
        let finishing = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }
        try await waitUntil("transcription to suspend") { transcriber.isWaiting }

        transcriber.succeed(with: transcription("Keep me"))
        let outcome = await finishing.value

        #expect(outcome == .notSent(transcription("Keep me"), message: PromptComposerDictationSession.notSentMessage))
        #expect(composer.draft.contains("Keep me"))
        #expect(composer.submissions.isEmpty)
        #expect(composer.reportedErrors == [PromptComposerDictationSession.notSentMessage])
    }

    @Test("An idle microphone click does nothing while unready")
    func externalMicStartRequiresReadiness() {
        let (session, _) = makeSession()
        #expect(session.externalMicAction(canStart: false) == .ignored)
        #expect(session.phase == .idle)
    }

    @Test("The submitted payload carries every staged item and the dictation marker")
    func submittedPayloadIsFullyComposed() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        composer.attachments = [attachment(status: .uploaded, uploaded: true)]
        composer.quotes = [ChatQuote(text: "Keep this response", comment: "Use it", source: "Synthetic")]

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.2
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Ship the fix")))

        #expect(outcome == .submitted(transcription("Ship the fix")))
        let payload = try #require(composer.submissions.first)
        #expect(payload.contains("Existing direction"))
        #expect(payload.contains("Ship the fix"))
        #expect(payload.contains("Quoted response segments:"))
        #expect(payload.contains("Attachment: `first-mate:synthetic-feature/attachment-1`"))
        #expect(payload.contains("(transcribed audio, please account for incorrect names or typos)"))
    }

    @Test("A duplicate Stop and a racing finish still submit once")
    func duplicateStopSubmitsOnce() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        #expect(session.beginExplicitStop())
        let first = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }
        try await waitUntil("transcription to suspend") { transcriber.isWaiting }
        let second = await session.finish(composer.completion(transcribe: transcriber.transcribe))
        #expect(second == .cancelled)

        transcriber.succeed(with: transcription("Only once"))
        let outcome = await first.value

        #expect(outcome == .submitted(transcription("Only once")))
        #expect(transcriber.startCount == 1)
        #expect(composer.submissions.count == 1)
    }

    @Test("An automatic duration completion retains the transcript without sending")
    func automaticCompletionDoesNotSend() async throws {
        let harness = QuickCaptureHarness()
        let session = PromptComposerDictationSession(capture: harness.capture)
        let composer = DictationComposerStub(draft: "Existing direction")

        #expect(session.beginDictation())
        let engine = try #require(harness.engine)
        engine.currentTime = 2.2
        // The recorder stops itself at its duration limit; no explicit Stop
        // intent exists, so this completion must not authorize a send.
        harness.recorder.handleCaptureFinished(engine, successfully: true)

        let outcome = await session.finish(composer.completion(transcribe: immediate("Limit reached")))

        #expect(outcome == .retained(transcription("Limit reached")))
        #expect(composer.submissions.isEmpty)
        #expect(composer.draft.contains("Limit reached"))
        #expect(composer.containsDictation)
    }

    // MARK: - Empty, short, failed, and cancelled

    @Test("An empty transcript never adds text and never sends the existing draft")
    func emptyTranscriptNeverSends() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.0
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("   \n ")))

        #expect(outcome == .empty)
        #expect(composer.draft == "Existing direction")
        #expect(!composer.containsDictation)
        #expect(composer.submissions.isEmpty)
        #expect(composer.reportedErrors.isEmpty)
    }

    @Test("A failed transcription never sends the existing draft")
    func failedTranscriptionNeverSends() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.0
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion { _ in
            throw VoiceTranscriptionError.emptyTranscript
        })

        guard case let .failed(message) = outcome else {
            Issue.record("Expected failure, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(composer.draft == "Existing direction")
        #expect(composer.submissions.isEmpty)
    }

    @Test("A too-short capture never sends the existing draft")
    func tooShortNeverSends() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")

        #expect(session.beginDictation())
        harness.engine?.currentTime = 0.1
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Ignored")))

        #expect(outcome == .tooShort)
        #expect(composer.draft == "Existing direction")
        #expect(composer.submissions.isEmpty)
    }

    @Test("A cancelled capture never transcribes or sends")
    func cancelledCaptureNeverSends() async throws {
        let (session, _) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")

        #expect(session.beginDictation())
        session.cancel()
        let outcome = await session.finish(composer.completion(transcribe: immediate("Ignored")))

        #expect(outcome == .cancelled)
        #expect(composer.draft == "Existing direction")
        #expect(composer.submissions.isEmpty)
    }

    // MARK: - Readiness and lifecycle

    @Test("An unready attachment keeps the transcript and explains why it was not sent")
    func unreadyAttachmentBlocksAutoSend() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()
        composer.attachments = [attachment(status: .uploading, uploaded: false)]

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Ship it anyway")))

        #expect(outcome == .notSent(transcription("Ship it anyway"), message: PromptComposerDictationSession.notSentMessage))
        #expect(composer.draft.contains("Ship it anyway"))
        #expect(composer.submissions.isEmpty)
        #expect(composer.reportedErrors == [PromptComposerDictationSession.notSentMessage])
    }

    @Test("Lost control keeps the transcript and explains why it was not sent")
    func lostControlBlocksAutoSend() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()
        composer.canControl = false

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Ship it anyway")))

        #expect(outcome == .notSent(transcription("Ship it anyway"), message: PromptComposerDictationSession.notSentMessage))
        #expect(composer.draft.contains("Ship it anyway"))
        #expect(composer.submissions.isEmpty)
        #expect(composer.reportedErrors.count == 1)
    }

    @Test("A failed submit keeps the transcript and does not retry by itself")
    func failedSubmitKeepsTranscript() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()
        composer.submitBehavior = { false }

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Keep me")))

        #expect(outcome == .notSent(transcription("Keep me"), message: PromptComposerDictationSession.notSentMessage))
        #expect(composer.draft.contains("Keep me"))
        #expect(composer.containsDictation)
        #expect(composer.submissions.count == 1)
        #expect(composer.reportedErrors.count == 1)
    }

    @Test("Accepted content is consumed while a newer edit survives")
    func acceptedSubmissionPreservesNewerEdit() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()
        composer.beforeSubmit = { composer.draft = "A newer edit typed while sending" }

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let outcome = await session.finish(composer.completion(transcribe: immediate("Original dictation")))

        #expect(outcome == .submitted(transcription("Original dictation")))
        #expect(composer.draft == "A newer edit typed while sending")
        #expect(composer.submissions.count == 1)
    }

    @Test("Invalidating a pending Stop keeps the transcript but never sends it")
    func invalidationKeepsTranscriptWithoutSending() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }
        try await waitUntil("transcription to suspend") { transcriber.isWaiting }

        session.invalidateAutoSubmit()
        transcriber.succeed(with: transcription("Do not send"))
        let outcome = await finishing.value

        #expect(outcome == .retained(transcription("Do not send")))
        #expect(composer.draft.contains("Do not send"))
        #expect(composer.submissions.isEmpty)
    }

    @Test("Switching away during transcription retains the original draft and never sends on return")
    func selectionChangeKeepsOriginalDraftWithoutSending() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }
        try await waitUntil("transcription to suspend") { transcriber.isWaiting }

        // The transcript may still land in its original live draft, but a
        // different selection owns the composer now.
        composer.isCurrent = false
        transcriber.succeed(with: transcription("Keep in the original feature"))
        let outcome = await finishing.value
        #expect(outcome == .retained(transcription("Keep in the original feature")))
        #expect(composer.draft.contains("Keep in the original feature"))

        // Switching back later must not revive the stale auto-submit intent.
        composer.isCurrent = true
        #expect(composer.submissions.isEmpty)
    }

    @Test("A reconnect or disappeared destination discards the late transcript")
    func lifecycleChangeDiscardsTranscript() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub(draft: "Existing direction")
        let transcriber = DeferredVoiceTranscriber()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(composer.completion(transcribe: transcriber.transcribe)) }
        try await waitUntil("transcription to suspend") { transcriber.isWaiting }

        composer.acceptsCompletion = false
        transcriber.succeed(with: transcription("Too late"))
        let outcome = await finishing.value

        #expect(outcome == .stale)
        #expect(composer.draft == "Existing direction")
        #expect(composer.submissions.isEmpty)
    }

    @Test("A finish that starts after the session already completed is cancelled")
    func repeatedFinishAfterCompletionIsCancelled() async throws {
        let (session, harness) = makeSession()
        let composer = DictationComposerStub()

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.1
        #expect(session.beginExplicitStop())
        let first = await session.finish(composer.completion(transcribe: immediate("Once")))
        let second = await session.finish(composer.completion(transcribe: immediate("Twice")))

        #expect(first == .submitted(transcription("Once")))
        #expect(second == .cancelled)
        #expect(composer.submissions.count == 1)
    }

    // MARK: - Live production wiring

    @Test("Losing control while transcription is suspended blocks the send")
    func liveReadinessLossBlocksSuspendedCompletion() async throws {
        let fixture = try await LiveComposerFixture()
        defer { fixture.dispose() }
        let lease = fixture.store.acquireControlLease(available: true)
        fixture.store.setComposerDraft("Existing direction", for: fixture.context)
        let view = fixture.makeView(canControl: true)
        let harness = QuickCaptureHarness()
        let session = PromptComposerDictationSession(capture: harness.capture)

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.4
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(view.dictationCompletion) }
        try await waitUntil("production transcription to suspend") {
            await fixture.client.transcriptionIsWaiting
        }

        // Control is lost while the transcript is still being produced. The
        // destination's `canControl`/`isSubmitting` snapshot still says ready,
        // so only the live store check can catch this.
        fixture.store.updateControlLease(lease, available: false)
        await fixture.client.succeedTranscription(with: "Ship the fix")
        let outcome = await finishing.value

        let expected = transcription("Ship the fix", provider: .parakeet, language: "en")
        #expect(outcome == .notSent(expected, message: PromptComposerDictationSession.notSentMessage))
        #expect(fixture.store.composerDraft(for: fixture.context).contains("Ship the fix"))
        #expect(fixture.store.error == PromptComposerDictationSession.notSentMessage)
        #expect(await fixture.client.sentTexts.isEmpty)
    }

    @Test("A stale unready snapshot still submits when the live destination is ready")
    func liveReadinessOverridesObsoleteSnapshot() async throws {
        let fixture = try await LiveComposerFixture()
        defer { fixture.dispose() }
        _ = fixture.store.acquireControlLease(available: true)
        fixture.store.setComposerDraft("Existing direction", for: fixture.context)
        // The destination was produced by a render that saw control as
        // unavailable; the live store says otherwise, so the send must land.
        let view = fixture.makeView(canControl: false)
        let harness = QuickCaptureHarness()
        let session = PromptComposerDictationSession(capture: harness.capture)

        #expect(session.beginDictation())
        harness.engine?.currentTime = 1.4
        #expect(session.beginExplicitStop())
        let finishing = Task { await session.finish(view.dictationCompletion) }
        try await waitUntil("production transcription to suspend") {
            await fixture.client.transcriptionIsWaiting
        }
        await fixture.client.succeedTranscription(with: "Ship the fix")
        let outcome = await finishing.value

        let expected = transcription("Ship the fix", provider: .parakeet, language: "en")
        #expect(outcome == .submitted(expected))
        let payload = try #require(await fixture.client.sentTexts.first)
        #expect(payload.contains("Existing direction"))
        #expect(payload.contains("Ship the fix"))
        #expect(payload.contains("(transcribed audio, please account for incorrect names or typos)"))
        #expect(fixture.store.composerDraft(for: fixture.context).isEmpty)
        #expect(!fixture.store.composerDrafts.containsDictation(for: fixture.snapshot.feature.id))
        #expect(fixture.store.error == nil)
    }

    // MARK: - Helpers

    private func makeSession() -> (session: PromptComposerDictationSession, harness: QuickCaptureHarness) {
        let harness = QuickCaptureHarness()
        return (PromptComposerDictationSession(capture: harness.capture), harness)
    }

    private func transcription(_ text: String) -> VoiceTranscription {
        VoiceTranscription(text: text, provider: .demo, language: nil, usedFallback: false)
    }

    private func transcription(
        _ text: String,
        provider: VoiceTranscriptionProvider,
        language: String?
    ) -> VoiceTranscription {
        VoiceTranscription(text: text, provider: provider, language: language, usedFallback: false)
    }

    private func immediate(_ text: String) -> @MainActor (URL) async throws -> VoiceTranscription {
        let value = transcription(text)
        return { _ in value }
    }

    private func destination(policy: PromptComposerVoicePolicy) -> PromptComposerDestination {
        PromptComposerDestination(
            voicePolicy: policy,
            id: "first-mate:synthetic-feature:lifecycle:synthetic",
            canControl: true,
            isSubmitting: false,
            isBusy: false,
            placeholder: "Synthetic",
            sendAccessibilityLabel: "Send",
            sendAccessibilityHint: "Sends synthetic direction",
            supportsAttachments: true,
            supportsVoice: true,
            supportsPaneTools: false,
            isCurrent: { true },
            acceptsCompletion: { true },
            isReadyToSubmit: { true },
            upload: { _, _ in throw APIError.invalidResponse },
            transcribe: { _ in throw APIError.invalidResponse },
            submit: { _ in true },
            reportError: { _ in },
            reportToast: { _ in }
        )
    }

    private func attachment(status: TerminalAttachmentStatus, uploaded: Bool) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: "synthetic.txt",
            sourceURL: URL(fileURLWithPath: "/tmp/herdr-first-mate-synthetic.txt"),
            byteCount: 9,
            sourceOwnership: .userSelected,
            status: status,
            uploaded: uploaded ? self.uploadedAttachment : nil,
            error: status == .failed ? "Synthetic upload failure" : nil
        )
    }

    private var uploadedAttachment: UploadedAttachment {
        UploadedAttachment(
            id: "attachment-1",
            filename: "synthetic.txt",
            originalFilename: "synthetic.txt",
            contentType: "text/plain",
            size: 9,
            path: "first-mate:synthetic-feature/attachment-1",
            workspaceID: "first-mate:synthetic-feature",
            createdAt: "2030-01-01T12:00:00Z"
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

// MARK: - Synthetic composer

/// Supplies the destination-bound operations the real `PromptComposerView`
/// passes to the session. Readiness, payload serialization, and accepted-item
/// consumption all use the production `PromptComposerSubmission` helpers so the
/// session drives the same contract the view does.
@MainActor
private final class DictationComposerStub {
    var draft: String
    var attachments: [TerminalAttachment] = []
    var quotes: [ChatQuote] = []
    var containsDictation = false
    var isCurrent = true
    var acceptsCompletion = true
    var canControl = true
    var isSubmitting = false
    var submitBehavior: @MainActor () async -> Bool = { true }
    /// Runs after the payload snapshot and before the awaited submission, to
    /// simulate edits or staged items arriving while a send is in flight.
    var beforeSubmit: (@MainActor () -> Void)?
    private(set) var submissions: [String] = []
    private(set) var reportedErrors: [String] = []

    init(draft: String = "") {
        self.draft = draft
    }

    func completion(
        transcribe: @escaping @MainActor (URL) async throws -> VoiceTranscription
    ) -> PromptComposerDictationSession.Completion {
        PromptComposerDictationSession.Completion(
            isCurrent: { self.isCurrent },
            acceptsCompletion: { self.acceptsCompletion },
            transcribe: transcribe,
            appendTranscript: { transcript in
                guard let updated = PromptComposerDictationSession.appending(transcript, to: self.draft) else { return }
                self.draft = updated
                self.containsDictation = true
            },
            canSubmit: {
                PromptComposerSubmission.isReady(
                    draft: self.draft,
                    attachments: self.attachments,
                    quoteCount: self.quotes.count,
                    conversationReferenceCount: 0,
                    isSubmitting: self.isSubmitting,
                    canControl: self.canControl,
                    dispositionIsAvailable: true
                ) && self.isCurrent
            },
            submit: {
                let draftToSend = self.draft
                let attachmentsToSend = self.attachments
                let quotesToSend = self.quotes
                let containsDictationToSend = self.containsDictation
                let message = PromptComposerSubmission.payload(
                    draft: draftToSend,
                    attachments: attachmentsToSend.filter { $0.status == .uploaded && $0.uploadedPath != nil },
                    quotes: quotesToSend,
                    references: [],
                    containsDictation: containsDictationToSend
                )
                self.beforeSubmit?()
                let accepted = await self.submitBehavior()
                self.submissions.append(message)
                guard accepted else { return false }

                var draft = self.draft
                var attachments = self.attachments
                var quotes = self.quotes
                var containsDictation = self.containsDictation
                PromptComposerSubmission.consumeAccepted(
                    sentDraft: draftToSend,
                    sentAttachmentIDs: Set(attachmentsToSend.map(\.id)),
                    sentQuoteIDs: Set(quotesToSend.map(\.id)),
                    sentContainsDictation: containsDictationToSend,
                    draft: &draft,
                    attachments: &attachments,
                    quotes: &quotes,
                    containsDictation: &containsDictation
                )
                self.draft = draft
                self.attachments = attachments
                self.quotes = quotes
                self.containsDictation = containsDictation
                return true
            },
            reportError: { self.reportedErrors.append($0) }
        )
    }
}

/// Suspends a transcription until the test releases it, so submission ordering
/// can be observed before any transcript exists.
@MainActor
private final class DeferredVoiceTranscriber {
    private var continuation: CheckedContinuation<VoiceTranscription, Error>?
    private(set) var startCount = 0

    var isWaiting: Bool { continuation != nil }

    func transcribe(_ url: URL) async throws -> VoiceTranscription {
        startCount += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VoiceTranscription, Error>) in
            self.continuation = continuation
        }
    }

    func succeed(with value: VoiceTranscription) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Production fixture

/// A First Mate store, model, and produced `PromptComposerView` wired through
/// the same `PromptComposerDestination.firstMate` factory the app uses, so
/// live-readiness coverage exercises production code rather than the stub.
@MainActor
private final class LiveComposerFixture {
    let client: DeferredFirstMateVoiceClient
    let store: FirstMateStore
    let model: HerdrAppModel
    let snapshot: FirstMateSnapshot
    let context: FirstMateStore.OperationContext
    private let userDefaultsSuite: String
    private let userDefaults: UserDefaults

    init() async throws {
        client = DeferredFirstMateVoiceClient()
        store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        context = store.operationContext
        snapshot = try #require(store.snapshot(for: context))
        userDefaultsSuite = "herdr-first-mate-voice-\(UUID().uuidString)"
        userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuite))
        model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: userDefaults)
    }

    func dispose() {
        userDefaults.removePersistentDomain(forName: userDefaultsSuite)
    }

    func makeView(canControl: Bool) -> PromptComposerView {
        let featureID = snapshot.feature.id
        let draft = Binding(
            get: { self.store.composerDraft(for: self.context) },
            set: { self.store.setComposerDraft($0, for: self.context) }
        )
        let containsDictation = Binding(
            get: { self.store.composerDrafts.containsDictation(for: featureID) },
            set: { self.store.composerDrafts.setContainsDictation($0, for: featureID) }
        )
        return PromptComposerView(
            model: model,
            destination: .firstMate(store: store, model: model, snapshot: snapshot, canControl: canControl),
            draft: draft,
            attachments: .constant([]),
            quotes: .constant([]),
            containsDictation: containsDictation,
            modelFavorites: ModelFavoritesStore(userDefaults: userDefaults)
        )
    }
}

/// Suspends First Mate's private transcription request until the test releases
/// it and records accepted sends, so readiness transitions can be observed
/// while the production completion is still awaiting a transcript.
private actor DeferredFirstMateVoiceClient: FirstMateClient {
    private var transcriptionContinuation: CheckedContinuation<VoiceTranscriptionResponse, Error>?
    private(set) var sentTexts: [String] = []

    var transcriptionIsWaiting: Bool { transcriptionContinuation != nil }

    func succeedTranscription(with text: String) {
        let response = VoiceTranscriptionResponse(ok: true, text: text, backend: "parakeet", language: "en")
        transcriptionContinuation?.resume(returning: response)
        transcriptionContinuation = nil
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

    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot {
        try await fetchFirstMateFeature(id)
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        sentTexts.append(text)
        guard let snapshot = FirstMateDemo.features(step: 0).first(where: { $0.feature.id == featureID }) else {
            throw APIError.invalidResponse
        }
        return snapshot
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        throw APIError.invalidResponse
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        throw APIError.invalidResponse
    }

    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        try await withCheckedThrowingContinuation { continuation in
            transcriptionContinuation = continuation
        }
    }
}
