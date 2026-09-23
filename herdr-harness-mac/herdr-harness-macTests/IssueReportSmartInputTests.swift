import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Issue report smart input", .serialized)
@MainActor
struct IssueReportSmartInputTests {
    @Test("Plain-English source drafts both fields and keeps the source text")
    func draftsBothFields() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "it crashes when I open two windows"
        harness.drafting.outcome = .success(
            IssueReportDraftOutput(title: "Crash with two windows", body: "## Steps\n1. Open two windows")
        )

        harness.smart.generate()
        try await waitUntil("draft applied") { !harness.smart.isDrafting }

        #expect(harness.composer.title == "Crash with two windows")
        #expect(harness.composer.body == "## Steps\n1. Open two windows")
        #expect(harness.smart.source == "it crashes when I open two windows")
        #expect(harness.drafting.draftCalls.count == 1)
        #expect(harness.drafting.draftCalls.first?.kind == .bug)
        #expect(harness.drafting.draftCalls.first?.machineID == "machine-1")
        #expect(!harness.composer.isPreparing)
        #expect(harness.smart.draftErrorMessage == nil)
    }

    @Test("The click-time report kind is what the companion receives")
    func capturesKindAtClickTime() async throws {
        let harness = SmartInputHarness()
        harness.composer.kind = .feature
        harness.smart.source = "add a quiet mode"
        harness.drafting.outcome = .success(IssueReportDraftOutput(title: "Quiet mode", body: "Rationale"))

        harness.smart.generate()
        try await waitUntil("draft applied") { !harness.smart.isDrafting }

        #expect(harness.drafting.draftCalls.first?.kind == .feature)
    }

    @Test("A second click while drafting starts no second run")
    func doubleClickDraftsOnce() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "only once"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("first draft started") { harness.drafting.draftCalls.count == 1 }
        harness.smart.generate()

        #expect(harness.drafting.draftCalls.count == 1)
        #expect(harness.smart.isDrafting)
        #expect(!harness.smart.canGenerate)

        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Once", body: "Body")))
        try await waitUntil("draft applied") { !harness.smart.isDrafting }
        #expect(harness.composer.title == "Once")
    }

    @Test("A kind change while drafting refuses the generated text")
    func kindChangeRefusesLateDraft() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("first draft started") { harness.drafting.draftCalls.count == 1 }
        harness.composer.kind = .feature
        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Late", body: "Late body")))
        try await waitUntil("late draft ignored") { !harness.smart.isDrafting }

        #expect(harness.composer.title.isEmpty)
        #expect(harness.composer.body.isEmpty)
        #expect(harness.smart.draftErrorMessage?.contains("changed while AI was drafting") == true)
    }

    @Test("An edit to the title while drafting wins over the generated text")
    func titleEditWins() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("first draft started") { harness.drafting.draftCalls.count == 1 }
        harness.composer.title = "My own title"
        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Late", body: "Late body")))
        try await waitUntil("late draft ignored") { !harness.smart.isDrafting }

        #expect(harness.composer.title == "My own title")
        #expect(harness.composer.body.isEmpty)
        #expect(harness.smart.draftErrorMessage != nil)
    }

    @Test("Source edits while drafting are preserved and the result still applies")
    func sourceEditDuringDrafting() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "first wording"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("first draft started") { harness.drafting.draftCalls.count == 1 }
        harness.smart.source = "second wording typed while waiting"
        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Drafted", body: "Body")))
        try await waitUntil("draft applied") { !harness.smart.isDrafting }

        #expect(harness.composer.title == "Drafted")
        #expect(harness.smart.source == "second wording typed while waiting")
    }

    @Test("A failed draft keeps the typed source and reports the failure")
    func failureKeepsSource() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "plain request"
        harness.drafting.outcome = .failure(IssueReportDraftError.runFailed("Pi provider is not configured"))

        harness.smart.generate()
        try await waitUntil("draft failed") { !harness.smart.isDrafting }

        #expect(harness.smart.source == "plain request")
        #expect(harness.smart.draftErrorMessage?.contains("Pi provider is not configured") == true)
        #expect(harness.composer.title.isEmpty)
        #expect(harness.composer.body.isEmpty)
        #expect(!harness.composer.isPreparing)
    }

    @Test("An older companion disables only the AI action")
    func unsupportedCompanionDisablesAI() async throws {
        let harness = SmartInputHarness()
        harness.drafting.availability = .unsupportedCompanion
        await harness.smart.refreshAvailability()

        #expect(harness.smart.availability == .unsupportedCompanion)
        harness.smart.source = "plain request"
        #expect(!harness.smart.canGenerate)

        harness.smart.generate()
        #expect(harness.drafting.draftCalls.isEmpty)

        // Manual reporting is untouched.
        harness.composer.title = "Hand-written title"
        harness.composer.body = "Hand-written body"
        #expect(harness.composer.canSubmit)
    }

    @Test("Preparation blocks submission and submission blocks preparation")
    func preparationAndSubmissionAreExclusive() async throws {
        let harness = SmartInputHarness()
        harness.composer.title = "Title"
        harness.composer.body = "Body"
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("drafting") { harness.smart.isDrafting }
        #expect(harness.composer.isPreparing)
        #expect(!harness.composer.canSubmit)

        harness.smart.cancel()
        #expect(!harness.composer.isPreparing)
        #expect(harness.composer.canSubmit)
        // Drain the suspended manual ask so its continuation never leaks.
        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Ignored", body: "Ignored")))

        harness.composer.phase = .submitting
        #expect(!harness.smart.canGenerate)
        harness.smart.generate()
        #expect(harness.drafting.draftCalls.count == 1)
    }

    @Test("Restoration is one step and refuses intervening edits")
    func restorationIsGuarded() async throws {
        let harness = SmartInputHarness()
        harness.composer.title = "My title"
        harness.composer.body = "My body"
        harness.composer.kind = .feature
        harness.smart.source = "request"
        harness.drafting.outcome = .success(IssueReportDraftOutput(title: "Generated", body: "Generated body"))

        harness.smart.generate()
        try await waitUntil("draft applied") { !harness.smart.isDrafting }
        #expect(harness.composer.title == "Generated")
        #expect(harness.smart.canRestoreGeneratedDraft)

        #expect(harness.smart.restoreGeneratedDraft())
        #expect(harness.composer.title == "My title")
        #expect(harness.composer.body == "My body")
        #expect(!harness.smart.canRestoreGeneratedDraft)
        #expect(!harness.smart.restoreGeneratedDraft())

        harness.smart.generate()
        try await waitUntil("draft applied again") { !harness.smart.isDrafting }
        harness.composer.title = "Newer edit"
        #expect(!harness.smart.canRestoreGeneratedDraft)
        #expect(!harness.smart.restoreGeneratedDraft())
        #expect(harness.composer.title == "Newer edit")
        #expect(harness.composer.body == "Generated body")
    }

    @Test("Cancelling drafting ignores a late completion")
    func cancelIgnoresLateDraft() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("drafting") { harness.smart.isDrafting }
        harness.smart.cancel()

        #expect(!harness.smart.isDrafting)
        #expect(!harness.composer.isPreparing)

        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Late", body: "Late body")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.composer.title.isEmpty)
        #expect(harness.composer.body.isEmpty)
    }

    @Test("Ending the sheet ignores a late completion and leaves no worker")
    func endSheetIgnoresLateDraft() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("drafting") { harness.smart.isDrafting }
        harness.smart.endSheet()

        #expect(!harness.smart.isSheetActive)
        #expect(!harness.smart.isBusy)
        #expect(!harness.composer.isPreparing)

        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "Late", body: "Late body")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.composer.title.isEmpty)
    }

    @Test("Permission pending is not recording")
    func permissionPendingIsNotRecording() async throws {
        let harness = SmartInputHarness()
        harness.capture.beginBehavior = .permissionRequest

        harness.smart.toggleRecording()
        #expect(harness.smart.voiceState == .requestingPermission)
        #expect(!harness.smart.isRecording)
        #expect(harness.smart.isBusy)
        #expect(harness.composer.isPreparing)

        harness.capture.simulateRecordingStarted()
        #expect(harness.smart.voiceState == .recording)
        #expect(harness.smart.isRecording)
    }

    @Test("Stop transcribes exactly once and appends to the smart input")
    func stopTranscribesOnce() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "typed before"
        harness.transcriber.outcome = .success("spoken words")

        harness.smart.toggleRecording()
        #expect(harness.smart.voiceState == .recording)
        harness.smart.toggleRecording()
        // A repeated Stop while the send is in flight starts no second send.
        harness.smart.toggleRecording()
        try await waitUntil("transcription finished") { harness.smart.voiceState == .idle }

        #expect(harness.capture.endCount == 1)
        #expect(harness.transcriber.calls.count == 1)
        #expect(harness.transcriber.calls.first?.machineID == "machine-1")
        #expect(harness.smart.source == "typed before\n\nspoken words")
        #expect(harness.composer.title.isEmpty)
        #expect(harness.composer.body.isEmpty)
        #expect(harness.capture.discardCount == 1)
        #expect(!harness.composer.isPreparing)
    }

    @Test("The automatic duration completion transcribes exactly once")
    func automaticFinishTranscribesOnce() async throws {
        let harness = SmartInputHarness()
        harness.transcriber.outcome = .success("spoken words")

        harness.smart.toggleRecording()
        #expect(harness.smart.voiceState == .recording)
        // The recorder emits the same finished-capture callback whether the
        // user clicked Stop or the ten-minute cap fired.
        harness.capture.simulateCaptureFinished()
        try await waitUntil("transcription finished") { harness.smart.voiceState == .idle }

        #expect(harness.transcriber.calls.count == 1)
        #expect(harness.smart.source == "spoken words")
    }

    @Test("A transcript appends to typing that happened while it transcribed")
    func transcriptionKeepsNewerTyping() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "typed first"
        harness.transcriber.outcome = .manual

        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcribing") { harness.smart.voiceState == .transcribing }

        harness.smart.source = "typed first and more"
        harness.transcriber.resolve(.success("spoken words"))
        try await waitUntil("transcription finished") { harness.smart.voiceState == .idle }

        #expect(harness.smart.source == "typed first and more\n\nspoken words")
    }

    @Test("An empty transcript retains the recording for an explicit retry")
    func emptyTranscriptRetainsRecording() async throws {
        let harness = SmartInputHarness()
        harness.transcriber.outcome = .success("   ")

        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcription failed") { harness.smart.voiceState == .failed }

        #expect(harness.smart.canRetryTranscription)
        #expect(harness.smart.voiceErrorMessage?.contains("Transcription failed") == true)
        #expect(harness.smart.source.isEmpty)
        #expect(harness.capture.discardCount == 0)
        #expect(harness.capture.outputURL != nil)
        #expect(!harness.composer.isPreparing)
    }

    @Test("A failed transcription retains the recording and retry discards it on success")
    func failedTranscriptionRetainsAndRetries() async throws {
        let harness = SmartInputHarness()
        harness.transcriber.outcome = .failure(VoiceTranscriptionError.invalidRecording)

        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcription failed") { harness.smart.voiceState == .failed }
        #expect(harness.smart.canRetryTranscription)
        #expect(harness.capture.discardCount == 0)

        harness.transcriber.outcome = .success("recovered words")
        harness.smart.retryTranscription()
        try await waitUntil("retry finished") { harness.smart.voiceState == .idle }

        #expect(harness.transcriber.calls.count == 2)
        #expect(harness.smart.source == "recovered words")
        #expect(!harness.smart.canRetryTranscription)
        #expect(harness.capture.discardCount == 1)
    }

    @Test("Discarding a failed recording clears the retry")
    func discardFailedRecording() async throws {
        let harness = SmartInputHarness()
        harness.transcriber.outcome = .failure(VoiceTranscriptionError.invalidRecording)

        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcription failed") { harness.smart.voiceState == .failed }

        harness.smart.discardFailedRecording()
        #expect(harness.smart.voiceState == .idle)
        #expect(!harness.smart.canRetryTranscription)
        #expect(harness.capture.discardCount == 1)
        #expect(harness.smart.source.isEmpty)
    }

    @Test("Over-limit source text is preserved with a validation message")
    func overLimitSourceIsPreserved() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = String(repeating: "x", count: 20_001)

        #expect(harness.smart.sourceProblem != nil)
        #expect(!harness.smart.canGenerate)

        // Transcription still appends instead of truncating either side.
        harness.transcriber.outcome = .success("spoken")
        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcription finished") { harness.smart.voiceState == .idle }

        #expect(harness.smart.source.count == 20_001 + 2 + 6)
        #expect(harness.smart.source.hasPrefix(String(repeating: "x", count: 20_001)))
        #expect(harness.smart.sourceProblem != nil)
        #expect(!harness.smart.canGenerate)
    }

    @Test("Permission denial is actionable and retains nothing")
    func permissionDeniedIsActionable() async throws {
        let harness = SmartInputHarness()
        harness.capture.beginBehavior = .denied

        harness.smart.toggleRecording()

        #expect(harness.smart.voiceState == .idle)
        #expect(harness.smart.voiceErrorMessage == "Microphone access is disabled for Herdr.")
        #expect(!harness.smart.canRetryTranscription)
        #expect(harness.capture.discardCount == 1)
        #expect(harness.transcriber.calls.isEmpty)
    }

    @Test("Cancelling while transcribing discards the recording and ignores the result")
    func cancelWhileTranscribing() async throws {
        let harness = SmartInputHarness()
        harness.transcriber.outcome = .manual

        harness.smart.toggleRecording()
        harness.smart.toggleRecording()
        try await waitUntil("transcribing") { harness.smart.voiceState == .transcribing }

        harness.smart.cancel()
        #expect(harness.smart.voiceState == .idle)
        #expect(harness.capture.discardCount == 1)

        harness.transcriber.resolve(.success("late words"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.smart.source.isEmpty)
    }

    @Test("A target change discards a recording and any retained audio")
    func targetChangeDiscardsAudio() async throws {
        let harness = SmartInputHarness()
        harness.smart.toggleRecording()
        #expect(harness.smart.voiceState == .recording)

        harness.reconfigure(machineID: "machine-2")

        #expect(harness.smart.voiceState == .idle)
        #expect(harness.capture.discardCount == 1)

        harness.capture.simulateCaptureFinished()
        try await Task.sleep(for: .milliseconds(10))
        #expect(harness.transcriber.calls.isEmpty)
    }

    @Test("Ending the sheet cancels a pending permission request and its late callback")
    func endSheetCancelsPendingPermission() async throws {
        let harness = SmartInputHarness()
        harness.capture.beginBehavior = .permissionRequest

        harness.smart.toggleRecording()
        #expect(harness.smart.voiceState == .requestingPermission)

        harness.smart.endSheet()
        #expect(!harness.smart.isSheetActive)
        #expect(harness.smart.voiceState == .idle)
        #expect(harness.capture.discardCount == 1)

        harness.capture.simulateCaptureFinished()
        try await Task.sleep(for: .milliseconds(10))
        #expect(harness.transcriber.calls.isEmpty)
    }

    @Test("Recording cannot start while a draft is in flight")
    func recordingBlockedWhileDrafting() async throws {
        let harness = SmartInputHarness()
        harness.smart.source = "request"
        harness.drafting.outcome = .manual

        harness.smart.generate()
        try await waitUntil("drafting") { harness.smart.isDrafting }

        #expect(!harness.smart.canStartRecording)
        harness.smart.toggleRecording()
        #expect(harness.capture.beginCount == 0)

        harness.drafting.resolveFirst(with: .success(IssueReportDraftOutput(title: "T", body: "B")))
        try await waitUntil("draft applied") { !harness.smart.isDrafting }
    }

    @Test("Refresh availability stays on the selected companion")
    func refreshAvailabilityUsesSelectedCompanion() async throws {
        let harness = SmartInputHarness()
        harness.drafting.availability = .unavailable("connection refused")
        await harness.smart.refreshAvailability()

        if case let .unavailable(reason) = harness.smart.availability {
            #expect(reason == "connection refused")
        } else {
            Issue.record("Expected an unavailable state")
        }
    }
}

// MARK: - Harness

@MainActor
private final class SmartInputHarness {
    let directory: URL
    let composer: IssueReportComposer
    let smart: IssueReportSmartInput
    let drafting: FakeIssueReportDrafting
    let capture: FakeIssueReportVoiceCapture
    let transcriber: FakeTranscriber

    init(machineID: String = "machine-1") {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "issue-smart-input-\(UUID().uuidString)")
        composer = IssueReportComposer(temporaryDirectory: directory)
        composer.machineID = machineID
        drafting = FakeIssueReportDrafting()
        capture = FakeIssueReportVoiceCapture()
        transcriber = FakeTranscriber()
        smart = IssueReportSmartInput(capture: capture)
        smart.attach(composer: composer)
        configure(machineID: machineID, service: drafting)
    }

    func reconfigure(machineID: String) {
        composer.machineID = machineID
        configure(machineID: machineID, service: drafting)
    }

    private func configure(machineID: String, service: FakeIssueReportDrafting) {
        smart.configure(machineID: machineID, service: service) { [transcriber] url, machineID in
            try await transcriber.transcribe(url: url, machineID: machineID)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FakeIssueReportDrafting: IssueReportDrafting {
    enum Outcome {
        case success(IssueReportDraftOutput)
        case failure(any Error)
        case manual
    }

    var availability: IssueReportDraftAvailability = .available
    var outcome: Outcome = .success(IssueReportDraftOutput(title: "Drafted title", body: "Drafted body"))
    private(set) var draftCalls: [(kind: IssueReportKind, text: String, machineID: String)] = []
    private var continuations: [(id: UUID, continuation: CheckedContinuation<IssueReportDraftOutput, any Error>)] = []

    func availability(for machineID: String) async -> IssueReportDraftAvailability {
        availability
    }

    func draft(kind: IssueReportKind, text: String, machineID: String) async throws -> IssueReportDraftOutput {
        draftCalls.append((kind, text, machineID))
        switch outcome {
        case let .success(output):
            return output
        case let .failure(error):
            throw error
        case .manual:
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    continuations.append((id, continuation))
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolve(id: id, with: .failure(CancellationError()))
                }
            }
        }
    }

    func resolveFirst(with result: Result<IssueReportDraftOutput, any Error>) {
        guard let first = continuations.first else { return }
        resolve(id: first.id, with: result)
    }

    private func resolve(id: UUID, with result: Result<IssueReportDraftOutput, any Error>) {
        guard let index = continuations.firstIndex(where: { $0.id == id }) else { return }
        let continuation = continuations.remove(at: index).continuation
        continuation.resume(with: result)
    }
}

@MainActor
private final class FakeIssueReportVoiceCapture: IssueReportVoiceCapturing {
    enum BeginBehavior {
        case recording
        case permissionRequest
        case denied
    }

    static let syntheticURL = URL(fileURLWithPath: "/tmp/synthetic-issue-report.wav")

    var beginBehavior: BeginBehavior = .recording
    var endCaptureTranscribable = true
    var isRequestingPermission = false
    var isRecording = false
    var hasTranscribableRecording = false
    var outputURL: URL?
    var errorMessage: String?
    var onStateChange: (() -> Void)?
    var onCaptureFinished: (() -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var discardCount = 0

    func beginCapture() {
        beginCount += 1
        switch beginBehavior {
        case .recording:
            simulateRecordingStarted()
        case .permissionRequest:
            isRequestingPermission = true
            onStateChange?()
        case .denied:
            errorMessage = "Microphone access is disabled for Herdr."
            onStateChange?()
        }
    }

    func endCapture() {
        endCount += 1
        simulateCaptureFinished(transcribable: endCaptureTranscribable)
    }

    func discard() {
        discardCount += 1
        isRequestingPermission = false
        isRecording = false
        hasTranscribableRecording = false
        errorMessage = nil
        outputURL = nil
        onStateChange?()
    }

    func simulateRecordingStarted() {
        isRequestingPermission = false
        isRecording = true
        hasTranscribableRecording = false
        outputURL = Self.syntheticURL
        onStateChange?()
    }

    func simulateCaptureFinished(transcribable: Bool = true) {
        isRecording = false
        hasTranscribableRecording = transcribable
        outputURL = Self.syntheticURL
        onCaptureFinished?()
        onStateChange?()
    }
}

@MainActor
private final class FakeTranscriber {
    enum Outcome {
        case success(String)
        case failure(any Error)
        case manual
    }

    var outcome: Outcome = .success("spoken words")
    private(set) var calls: [(url: URL, machineID: String)] = []
    private var continuation: CheckedContinuation<String, any Error>?

    func transcribe(url: URL, machineID: String) async throws -> String {
        calls.append((url, machineID))
        switch outcome {
        case let .success(text):
            return text
        case let .failure(error):
            throw error
        case .manual:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolve(.failure(CancellationError()))
                }
            }
        }
    }

    func resolve(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
