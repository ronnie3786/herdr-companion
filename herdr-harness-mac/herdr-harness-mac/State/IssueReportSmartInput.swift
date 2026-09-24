import Foundation
import Observation

/// A recording engine the smart-input section can drive without knowing
/// whether it is backed by the real microphone or a test double.
@MainActor
protocol IssueReportVoiceCapturing: AnyObject {
    /// True while the system permission prompt is up and capture has not
    /// started. The glow must key off `isRecording`, never this.
    var isRequestingPermission: Bool { get }
    var isRecording: Bool { get }
    /// True only when a finished recording exists, is long enough to send for
    /// transcription, and still has its file.
    var hasTranscribableRecording: Bool { get }
    var outputURL: URL? { get }
    var errorMessage: String? { get }
    var onStateChange: (() -> Void)? { get set }
    var onCaptureFinished: (() -> Void)? { get set }
    func beginCapture()
    func endCapture()
    func discard()
}

/// Wraps `HerdrVoiceRecorder` for the report sheet.
///
/// The recorder is shared with the other voice entry points, so this adapter
/// changes nothing about its WAV settings, metering, or ten-minute maximum; it
/// only exposes permission-pending separately from actual capture and lets the
/// one finished-capture callback converge explicit Stop and the automatic
/// duration completion on a single transcription.
@MainActor
final class IssueReportVoiceCaptureAdapter: IssueReportVoiceCapturing {
    /// Mirrors `HerdrQuickVoiceCapture.minimumDuration`: a shorter recording
    /// has no speech to transcribe.
    static let minimumDuration: TimeInterval = 0.5

    private let recorder: HerdrVoiceRecorder

    init(recorder: HerdrVoiceRecorder = HerdrVoiceRecorder()) {
        self.recorder = recorder
    }

    var isRequestingPermission: Bool { recorder.isRequestingPermission }
    var isRecording: Bool { recorder.isRecording }
    var hasTranscribableRecording: Bool {
        recorder.canSave && recorder.elapsedTime >= Self.minimumDuration
    }
    var outputURL: URL? { recorder.outputURL }
    var errorMessage: String? { recorder.errorMessage }

    var onStateChange: (() -> Void)? {
        get { recorder.onStateChange }
        set { recorder.onStateChange = newValue }
    }

    var onCaptureFinished: (() -> Void)? {
        get { recorder.onCaptureFinished }
        set { recorder.onCaptureFinished = newValue }
    }

    func beginCapture() { recorder.startRecording() }
    func endCapture() { recorder.stopRecording() }
    func discard() { recorder.discard() }
}

/// Transcribes one retained WAV on the companion that captured it. The live
/// wiring is `HerdrAppModel.transcribeQuickVoice(at:machineID:)`; tests inject
/// a synthetic closure.
typealias IssueReportVoiceTranscriber = @MainActor (URL, String) async throws -> String

/// State and guards behind the report sheet's optional smart-input section.
///
/// The section is deliberately separate from the existing title/description
/// fields: recording only appends into `source`, and AI drafting only writes
/// into the composer through a token that pins the report kind, target, and
/// field revision. Dismissal, cancellation, and a target change all discard
/// work and any retained audio, and a late completion can never touch a
/// closed sheet.
@MainActor
@Observable
final class IssueReportSmartInput {
    enum VoiceState: Equatable, Sendable {
        case idle
        case requestingPermission
        case recording
        case transcribing
        case failed
    }

    /// The raw plain-English request. Never sent anywhere except one explicit
    /// drafting run or one explicit transcription.
    var source = ""

    private(set) var availability: IssueReportDraftAvailability = .unknown
    private(set) var isDrafting = false
    private(set) var voiceState: VoiceState = .idle
    private(set) var draftErrorMessage: String?
    private(set) var voiceErrorMessage: String?
    /// True while a failed transcription's audio is retained for an explicit
    /// in-sheet retry.
    private(set) var canRetryTranscription = false
    private(set) var isSheetActive = true

    @ObservationIgnored weak var composer: IssueReportComposer?
    @ObservationIgnored private let capture: any IssueReportVoiceCapturing
    @ObservationIgnored private var drafting: (any IssueReportDrafting)?
    @ObservationIgnored private var transcriber: IssueReportVoiceTranscriber?
    @ObservationIgnored private var configuredMachineID = ""
    @ObservationIgnored private var captureMachineID = ""
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var activeDraftOperation: UUID?
    @ObservationIgnored private var voiceSession = 0
    @ObservationIgnored private var availabilityGeneration = 0

    init(capture: (any IssueReportVoiceCapturing)? = nil) {
        let capture = capture ?? IssueReportVoiceCaptureAdapter()
        self.capture = capture
        capture.onStateChange = { [weak self] in self?.captureStateChanged() }
        capture.onCaptureFinished = { [weak self] in self?.captureFinished() }
    }

    deinit {
        draftTask?.cancel()
        transcribeTask?.cancel()
    }

    // MARK: - Derived state

    /// True while any preparation is in flight. The composer blocks submission
    /// for exactly this long, so a report can never be filed halfway through
    /// replacing its own fields.
    var isBusy: Bool {
        isDrafting
            || voiceState == .requestingPermission
            || voiceState == .recording
            || voiceState == .transcribing
    }

    var isRecording: Bool { voiceState == .recording }

    /// Why the source text cannot be sent for drafting, or nil. An over-limit
    /// or control-bearing request keeps every character in the box and shows
    /// this instead of being truncated.
    var sourceProblem: String? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return IssueReportDraftProfile.sourceProblem(source)?.errorDescription
    }

    var canGenerate: Bool {
        guard isSheetActive, !isBusy, drafting != nil else { return false }
        guard composer?.canPrepare ?? true else { return false }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard sourceProblem == nil else { return false }
        if case .unsupportedCompanion = availability { return false }
        return true
    }

    var canStartRecording: Bool {
        guard isSheetActive, voiceState == .idle || voiceState == .failed else { return false }
        guard !isDrafting, composer?.canPrepare ?? true else { return false }
        guard composer?.machineID.isEmpty == false else { return false }
        return true
    }

    /// True while the inline control should offer Stop, including the prompt
    /// before capture actually begins.
    var canToggleRecording: Bool {
        canStartRecording || voiceState == .recording || voiceState == .requestingPermission
    }

    var canRestoreGeneratedDraft: Bool { composer?.canRestoreGeneratedDraft ?? false }

    // MARK: - Wiring

    /// Binds the report draft this section prepares. The composer holds the
    /// fields and every application guard; this state never keeps it alive.
    func attach(composer: IssueReportComposer) {
        self.composer = composer
        updateComposerPreparation()
    }

    /// Binds the exact companion's drafting service and transcription route.
    /// A nil service means this companion cannot draft at all (demo mode, no
    /// active connection, or an older app build); recording and manual
    /// reporting still work. A changed target cancels in-flight work and
    /// discards any retained audio before the new companion can be used.
    func configure(
        machineID: String,
        service: (any IssueReportDrafting)?,
        transcriber: @escaping IssueReportVoiceTranscriber
    ) {
        drafting = service
        self.transcriber = transcriber
        if configuredMachineID != machineID {
            configuredMachineID = machineID
            invalidateInFlightWork(discardRecording: true)
            availability = .unknown
            draftErrorMessage = nil
            voiceErrorMessage = nil
        }
    }

    /// Re-probes only the currently selected companion's advertised
    /// `issue-report-draft-v1` profile.
    func refreshAvailability() async {
        guard let drafting, let machineID = composer?.machineID, !machineID.isEmpty else {
            availability = .unavailable(IssueReportDraftError.noCompanion.localizedDescription)
            return
        }
        availabilityGeneration &+= 1
        let generation = availabilityGeneration
        let result = await drafting.availability(for: machineID)
        guard generation == availabilityGeneration, machineID == composer?.machineID else { return }
        availability = result
    }

    // MARK: - Drafting

    /// Starts exactly one explicit drafting run for the current source text.
    /// Repeated clicks while busy are ignored, and the request captures the
    /// report kind, target, and field revision so a late result cannot apply
    /// over newer edits.
    func generate() {
        guard canGenerate, let composer, let drafting else { return }
        let kind = composer.kind
        let machineID = composer.machineID
        let text = source
        let token = composer.draftToken
        let operation = UUID()
        activeDraftOperation = operation
        isDrafting = true
        draftErrorMessage = nil
        updateComposerPreparation()

        draftTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await drafting.draft(kind: kind, text: text, machineID: machineID)
                self.completeDrafting(operation: operation, token: token, result: .success(output))
            } catch {
                self.completeDrafting(operation: operation, token: token, result: .failure(error))
            }
        }
    }

    /// Restores the fields replaced by the most recent generated draft when
    /// nothing has edited them since. The composer refuses anything else.
    @discardableResult
    func restoreGeneratedDraft() -> Bool {
        composer?.restoreGeneratedDraft() ?? false
    }

    func dismissDraftError() {
        draftErrorMessage = nil
    }

    // MARK: - Recording

    /// One inline control: start, stop, or cancel a permission prompt. Stop
    /// and the recorder's automatic duration completion both end in exactly
    /// one transcription through `captureFinished`.
    func toggleRecording() {
        switch voiceState {
        case .recording:
            capture.endCapture()
        case .requestingPermission:
            cancelPendingRecording()
        case .idle, .failed:
            startRecording()
        case .transcribing:
            break
        }
    }

    /// Sends the retained failed recording to transcription again. Only ever
    /// reached from an explicit action in the open sheet.
    func retryTranscription() {
        guard voiceState == .failed, canRetryTranscription, let url = capture.outputURL else { return }
        voiceErrorMessage = nil
        beginTranscription(url: url)
    }

    /// Discards a failed recording without sending it anywhere.
    func discardFailedRecording() {
        guard voiceState == .failed else { return }
        capture.discard()
        canRetryTranscription = false
        voiceState = .idle
        voiceErrorMessage = nil
        updateComposerPreparation()
    }

    func dismissVoiceError() {
        voiceErrorMessage = nil
    }

    // MARK: - Lifecycle

    /// Cancels drafting and recording, discards any retained audio, and clears
    /// errors. Safe to call when nothing is running.
    func cancel() {
        guard isBusy || canRetryTranscription else { return }
        invalidateInFlightWork(discardRecording: true)
        draftErrorMessage = nil
        voiceErrorMessage = nil
    }

    /// Ends this sheet's preparation for good. A late permission grant,
    /// transcription result, or generated draft can no longer touch anything.
    func endSheet() {
        guard isSheetActive else { return }
        isSheetActive = false
        invalidateInFlightWork(discardRecording: true)
        draftErrorMessage = nil
        voiceErrorMessage = nil
    }

    // MARK: - Draft completion

    private func completeDrafting(
        operation: UUID,
        token: IssueReportDraftToken,
        result: Result<IssueReportDraftOutput, any Error>
    ) {
        guard operation == activeDraftOperation else { return }
        activeDraftOperation = nil
        draftTask = nil
        isDrafting = false
        defer { updateComposerPreparation() }
        guard isSheetActive else { return }

        switch result {
        case let .success(output):
            guard let composer, composer.applyGeneratedDraft(output, token: token) else {
                draftErrorMessage = "Your report changed while AI was drafting, so the generated text was not applied. "
                    + "Your edits are untouched — draft again to replace them."
                return
            }
            draftErrorMessage = nil
        case let .failure(error):
            if error is CancellationError { return }
            let message = Self.userMessage(for: error)
            if let draftError = error as? IssueReportDraftError, case .cancelled = draftError { return }
            if let draftError = error as? IssueReportDraftError, case .unsupportedCompanion = draftError {
                availability = .unsupportedCompanion
            }
            draftErrorMessage = message
        }
    }

    /// A user-facing reason that never renders an `Optional(...)` string.
    private static func userMessage(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Capture

    private func startRecording() {
        guard canStartRecording else { return }
        // A new capture replaces any recording retained for retry.
        discardFailedRecording()
        voiceErrorMessage = nil
        canRetryTranscription = false
        captureMachineID = composer?.machineID ?? ""
        voiceSession &+= 1
        voiceState = capture.isRequestingPermission ? .requestingPermission : .recording
        capture.beginCapture()
        captureStateChanged()
    }

    private func cancelPendingRecording() {
        guard voiceState == .requestingPermission else { return }
        voiceSession &+= 1
        capture.discard()
        voiceState = .idle
        voiceErrorMessage = nil
        updateComposerPreparation()
    }

    /// Mirrors the recorder's state. Permission pending is not recording, and
    /// a denial or capture failure is actionable without any audio retained.
    private func captureStateChanged() {
        // A recorder notification after the sheet closed needs no state; the
        // sheet's own teardown already discarded the file.
        guard isSheetActive else { return }
        if let message = capture.errorMessage, voiceState != .transcribing {
            voiceErrorMessage = message
            canRetryTranscription = false
            capture.discard()
            voiceState = .idle
            updateComposerPreparation()
            return
        }
        if capture.isRequestingPermission {
            voiceState = .requestingPermission
        } else if capture.isRecording {
            voiceState = .recording
        } else if !capture.hasTranscribableRecording,
                  voiceState == .recording || voiceState == .requestingPermission {
            // A capture that ends without a usable file; the transcribable
            // case is handled by `captureFinished`.
            voiceState = .idle
        }
        updateComposerPreparation()
    }

    private func captureFinished() {
        guard isSheetActive else {
            capture.discard()
            return
        }
        guard voiceState == .recording || voiceState == .requestingPermission else {
            // A late callback after cancel, replacement, or a finished
            // transcription must never start a second send.
            return
        }
        guard capture.hasTranscribableRecording, let url = capture.outputURL else {
            let message = capture.errorMessage ?? "Record at least half a second before stopping."
            capture.discard()
            voiceErrorMessage = message
            canRetryTranscription = false
            voiceState = .idle
            updateComposerPreparation()
            return
        }
        beginTranscription(url: url)
    }

    private func beginTranscription(url: URL) {
        guard let transcriber,
              !captureMachineID.isEmpty,
              composer?.machineID == captureMachineID
        else {
            capture.discard()
            voiceErrorMessage = IssueReportDraftError.noCompanion.errorDescription
            canRetryTranscription = false
            voiceState = .idle
            updateComposerPreparation()
            return
        }
        voiceSession &+= 1
        let session = voiceSession
        voiceState = .transcribing
        voiceErrorMessage = nil
        canRetryTranscription = false
        updateComposerPreparation()

        transcribeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await transcriber(url, self.captureMachineID)
                self.finishTranscription(session: session, url: url, text: text)
            } catch {
                self.failTranscription(session: session, error: error)
            }
        }
    }

    private func finishTranscription(session: Int, url: URL, text: String) {
        guard session == voiceSession, isSheetActive else { return }
        transcribeTask = nil
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            failTranscription(session: session, error: VoiceTranscriptionError.emptyTranscript)
            return
        }
        appendTranscript(transcript)
        capture.discard()
        voiceState = .idle
        canRetryTranscription = false
        voiceErrorMessage = nil
        updateComposerPreparation()
    }

    private func failTranscription(session: Int, error: any Error) {
        guard session == voiceSession, isSheetActive else { return }
        transcribeTask = nil
        if error is CancellationError { return }
        let reason = Self.userMessage(for: error)
        // Keep the file only for an explicit in-sheet retry.
        canRetryTranscription = true
        voiceState = .failed
        voiceErrorMessage = "Transcription failed. \(reason) Your recording is still here — retry to use it again, "
            + "or discard it."
        updateComposerPreparation()
    }

    /// Appends to whatever the box holds right now. Typing that happened while
    /// the recording was transcribed is never replaced, and the title and
    /// description fields are not touched.
    private func appendTranscript(_ transcript: String) {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = transcript
        } else {
            source += "\n\n" + transcript
        }
    }

    // MARK: - Invalidation

    private func invalidateInFlightWork(discardRecording: Bool) {
        activeDraftOperation = nil
        draftTask?.cancel()
        draftTask = nil
        isDrafting = false
        transcribeTask?.cancel()
        transcribeTask = nil
        voiceSession &+= 1
        // Discard only when there is something to clean up; an idle section
        // must not churn the recorder on every configure or cancel call.
        let hasAudio = voiceState != .idle || canRetryTranscription || capture.outputURL != nil
        if discardRecording, hasAudio {
            capture.discard()
        }
        voiceState = .idle
        canRetryTranscription = false
        updateComposerPreparation()
    }

    private func updateComposerPreparation() {
        composer?.isPreparing = isBusy
    }
}
