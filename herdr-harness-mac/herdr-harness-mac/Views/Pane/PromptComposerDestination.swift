import Foundation

/// How a destination wires its two voice entry points.
///
/// `.legacy` is the default for every existing caller: the microphone outside
/// More opens the long-form voice-note recorder and More offers inline
/// dictation that appends to the draft. First Mate opts into
/// `.firstMateStopToSend`: that external microphone starts click-to-stop inline
/// dictation whose explicit Stop transcribes and submits, while More opens the
/// unchanged recorder sheet.
enum PromptComposerVoicePolicy: Equatable, Sendable {
    case legacy
    case firstMateStopToSend
}

/// What one of the composer's voice controls does.
enum PromptComposerVoiceRole: Equatable, Sendable {
    /// Opens the long-form voice-note recorder sheet.
    case openRecorder
    /// Starts or finishes inline dictation. Whether its Stop also submits is
    /// decided by `PromptComposerVoicePolicy.submitsOnExplicitStop`.
    case dictate
}

extension PromptComposerVoicePolicy {
    /// The microphone outside More.
    var externalVoiceRole: PromptComposerVoiceRole {
        switch self {
        case .legacy: .openRecorder
        case .firstMateStopToSend: .dictate
        }
    }

    /// The voice row inside More.
    var menuVoiceRole: PromptComposerVoiceRole {
        switch self {
        case .legacy: .dictate
        case .firstMateStopToSend: .openRecorder
        }
    }

    /// True when an explicit inline-dictation Stop transcribes and submits
    /// without another Send click. This is First Mate only.
    var submitsOnExplicitStop: Bool {
        self == .firstMateStopToSend
    }
}

/// First Mate reserves its outgoing row before the transport suspends. Other
/// destinations keep their acknowledgement-time cleanup.
enum PromptComposerSubmissionPolicy {
    case onAcceptance
    case optimistic(
        reserve: @MainActor (String, FirstMateOutgoingMessage.Submission, [TerminalAttachment], [ChatQuote]) -> FirstMateOutgoingMessage.Handle?,
        didDetach: @MainActor (FirstMateOutgoingMessage.Handle) -> Void,
        complete: @MainActor (FirstMateOutgoingMessage.Handle) async -> Bool,
        settle: @MainActor (FirstMateOutgoingMessage.Handle, Bool) -> Void
    )
}

/// Destination-neutral operations for the shared Mac prompt composer.
///
/// The identity is captured before every suspension. A completion may mutate
/// composer state only while `isCurrent` still confirms that exact destination.
struct PromptComposerDestination: Equatable {
    /// Default-preserving so every existing destination keeps the behavior it
    /// had before First Mate opted into dictation Stop-to-send.
    var voicePolicy: PromptComposerVoicePolicy = .legacy
    var submissionPolicy: PromptComposerSubmissionPolicy = .onAcceptance
    let id: String
    let canControl: Bool
    let isSubmitting: Bool
    let isBusy: Bool
    let placeholder: String
    let sendAccessibilityLabel: String
    let sendAccessibilityHint: String
    let supportsAttachments: Bool
    let supportsVoice: Bool
    let supportsPaneTools: Bool
    let isCurrent: @MainActor () -> Bool
    let acceptsCompletion: @MainActor () -> Bool
    /// Live readiness for this destination's next submission. `canControl`,
    /// `isSubmitting`, and `isBusy` above describe the render that produced
    /// this value; a completion that resumes after a suspension re-reads this
    /// closure instead, so a readiness change during transcription cannot let
    /// a stale permission submit or a stale block suppress a valid send.
    /// Supplied by the owner from current state (for First Mate: the live
    /// store's control, sending, and destination-alive state).
    let isReadyToSubmit: @MainActor () -> Bool
    let upload: @MainActor (URL, String) async throws -> UploadedAttachment
    let transcribe: @MainActor (URL) async throws -> VoiceTranscription
    let submit: @MainActor (String) async -> Bool
    let reportError: @MainActor (String) -> Void
    let reportToast: @MainActor (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.canControl == rhs.canControl
            && lhs.isSubmitting == rhs.isSubmitting
            && lhs.isBusy == rhs.isBusy
            && lhs.placeholder == rhs.placeholder
            && lhs.sendAccessibilityLabel == rhs.sendAccessibilityLabel
            && lhs.sendAccessibilityHint == rhs.sendAccessibilityHint
            && lhs.supportsAttachments == rhs.supportsAttachments
            && lhs.supportsVoice == rhs.supportsVoice
            && lhs.supportsPaneTools == rhs.supportsPaneTools
            && lhs.voicePolicy == rhs.voicePolicy
    }
}

struct PromptComposerPaneContext {
    let model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
}

extension PromptComposerDestination {
    /// The production completion wiring for one composer's inline dictation.
    ///
    /// The composer supplies the operations that read its live bindings;
    /// destination identity, transcription, readiness, and error reporting are
    /// re-read from this destination so a completion that resumes after a
    /// suspension never trusts the view value that created it. Kept here so
    /// tests can exercise the same wiring the view passes to the session.
    func dictationCompletion(
        appendTranscript: @escaping @MainActor (String) -> Void,
        hasReadyContent: @escaping @MainActor () -> Bool,
        submit: @escaping @MainActor () async -> Bool
    ) -> PromptComposerDictationSession.Completion {
        PromptComposerDictationSession.Completion(
            isCurrent: { [isCurrent] in isCurrent() },
            acceptsCompletion: { [acceptsCompletion] in acceptsCompletion() },
            transcribe: { [transcribe] url in try await transcribe(url) },
            appendTranscript: appendTranscript,
            canSubmit: { [isReadyToSubmit] in isReadyToSubmit() && hasReadyContent() },
            submit: submit,
            reportError: { [reportError] in reportError($0) }
        )
    }
}
