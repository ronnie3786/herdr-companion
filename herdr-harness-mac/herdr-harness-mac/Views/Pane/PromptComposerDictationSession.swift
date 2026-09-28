import Foundation
import Observation

/// Owns one composer's inline dictation and its exactly-once completion.
///
/// The shared composer has several Stop affordances (the microphone outside
/// More, the primary button, the status bar, and the recorder's automatic
/// duration limit), and each can arrive as an independent callback. This type
/// serializes them:
///
/// - only one capture and one completion can be active at a time;
/// - an explicit Stop records its auto-submit intent *before* transcription
///   suspends, so a late click can never upgrade an automatic recorder
///   completion into one that sends;
/// - leaving, backgrounding, or replacing the destination invalidates a
///   pending auto-submit without discarding the recording that is already
///   being transcribed;
/// - a completed transcript is appended to the live draft and, only when the
///   explicit Stop intent survived the await and the live composer is ready,
///   dispatched through the composer's normal submission path.
///
/// First Mate opts into the auto-submit behavior; every other destination uses
/// this same session with the draft-only contract.
@MainActor
@Observable
final class PromptComposerDictationSession {
    /// Destination-bound operations for one completion.
    ///
    /// The composer supplies these from its live bindings, so `canSubmit` and
    /// `submit` are re-read after transcription finishes instead of relying on
    /// a pre-await snapshot.
    struct Completion {
        var isCurrent: @MainActor () -> Bool
        var acceptsCompletion: @MainActor () -> Bool
        var transcribe: @MainActor (URL) async throws -> VoiceTranscription
        /// Appends the nonempty, trimmed transcript to the live draft.
        var appendTranscript: @MainActor (String) -> Void
        /// Live readiness check: control, destination, and attachment state.
        var canSubmit: @MainActor () -> Bool
        /// Submits through the composer's single normal submission path.
        var submit: @MainActor () async -> Bool
        var reportError: @MainActor (String) -> Void
    }

    enum Outcome: Equatable {
        case cancelled
        case tooShort
        case empty
        /// The transcript was appended to the draft without submitting.
        case retained(VoiceTranscription)
        /// The transcript was appended and the destination accepted the send.
        case submitted(VoiceTranscription)
        /// The transcript was appended, but submitting was blocked or failed.
        case notSent(VoiceTranscription, message: String)
        case failed(String)
        /// The destination lifecycle ended before the transcript could land.
        case stale
    }

    /// What one click on the external dictation microphone does.
    enum ExternalMicAction: Equatable {
        case start
        case stop
        case ignored
    }

    /// The one explanation shown when a completed dictation could not be sent.
    static let notSentMessage = "The transcription is in the prompt, but it wasn't sent. Resolve any blocked attachment or connection issue, then press Send to retry."

    let capture: HerdrQuickVoiceCapture

    private var sessionToken: UUID?
    private var explicitStopToken: UUID?
    private var invalidation = 0
    private var isFinishingCompletion = false

    init(capture: HerdrQuickVoiceCapture = HerdrQuickVoiceCapture()) {
        self.capture = capture
    }

    var phase: HerdrQuickVoiceCapture.Phase { capture.phase }
    var samples: [CGFloat] { capture.samples }
    var recorderStatus: HerdrVoiceRecorderStatus { capture.recorderStatus }

    var isRecording: Bool {
        capture.phase == .recording || capture.phase == .locked
    }

    var isBusy: Bool {
        isFinishingCompletion || capture.phase == .transcribing
    }

    /// Starts one click-to-stop dictation session. Returns false while another
    /// capture, transcription, or completion owns this composer.
    @discardableResult
    func beginDictation() -> Bool {
        guard !isFinishingCompletion, capture.phase == .idle else { return false }
        sessionToken = UUID()
        explicitStopToken = nil
        capture.beginLocked()
        return true
    }

    /// Records the explicit Stop intent before any suspension. Returns false
    /// when no recording is active or a completion already owns the capture,
    /// so a late Stop cannot change an in-flight automatic completion.
    @discardableResult
    func beginExplicitStop() -> Bool {
        guard !isFinishingCompletion else { return false }
        guard capture.phase == .recording || capture.phase == .locked else { return false }
        explicitStopToken = sessionToken
        return true
    }

    /// What one click on the external dictation microphone should do. Starting
    /// records the session token; stopping records the explicit-stop intent
    /// before returning, so the caller only has to finish the capture.
    func externalMicAction() -> ExternalMicAction {
        if isRecording {
            beginExplicitStop()
            return .stop
        }
        guard phase == .idle, !isBusy, beginDictation() else { return .ignored }
        return .start
    }

    /// Finishes the active capture exactly once and applies the completion
    /// contract: append a nonempty transcript, then submit only when an
    /// explicit Stop requested it and the live destination is ready.
    func finish(_ completion: Completion) async -> Outcome {
        guard !isFinishingCompletion else { return .cancelled }
        switch capture.phase {
        case .recording, .locked:
            break
        case .idle, .transcribing:
            return .cancelled
        }

        isFinishingCompletion = true
        defer { isFinishingCompletion = false }

        let token = sessionToken
        let invalidatedAtStart = invalidation
        let wasExplicitStop = explicitStopToken != nil && explicitStopToken == token
        explicitStopToken = nil

        let raw = await capture.endHold { url in
            try await completion.transcribe(url)
        }
        sessionToken = nil

        switch raw {
        case .cancelled:
            return .cancelled
        case .tooShort:
            return .tooShort
        case let .failure(message):
            return .failed(message)
        case let .transcript(transcription):
            let cleaned = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .empty }
            guard completion.acceptsCompletion() else { return .stale }
            completion.appendTranscript(cleaned)

            // The explicit-stop intent and the invalidation marker are
            // re-checked after the await. A destination change, background,
            // disappearance, or reconnect keeps the transcript as a draft but
            // never sends it.
            guard wasExplicitStop,
                  invalidatedAtStart == invalidation,
                  completion.isCurrent()
            else { return .retained(transcription) }

            guard completion.canSubmit() else {
                completion.reportError(Self.notSentMessage)
                return .notSent(transcription, message: Self.notSentMessage)
            }
            guard await completion.submit() else {
                completion.reportError(Self.notSentMessage)
                return .notSent(transcription, message: Self.notSentMessage)
            }
            return .submitted(transcription)
        }
    }

    /// Clears pending auto-submit intent without touching a transcription that
    /// is already running. The transcript may still be retained in its original
    /// live draft, but it will never be submitted on the strength of a stale
    /// explicit Stop.
    func invalidateAutoSubmit() {
        invalidation += 1
        explicitStopToken = nil
    }

    /// Cancels the capture and every pending intent. Unlike
    /// `invalidateAutoSubmit`, this also discards an idle or recording capture.
    func cancel() {
        invalidateAutoSubmit()
        capture.cancel()
        sessionToken = nil
    }

    /// The composer's single draft-append rule: trim, keep a blank-line
    /// separator, and refuse empty transcripts. Returns nil when nothing would
    /// be added, so callers can treat that as "no speech detected".
    nonisolated static func appending(_ transcript: String, to draft: String) -> String? {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? cleaned : "\(existing)\n\n\(cleaned)"
    }
}
