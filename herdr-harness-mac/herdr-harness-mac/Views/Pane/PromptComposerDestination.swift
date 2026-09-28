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

/// Destination-neutral operations for the shared Mac prompt composer.
///
/// The identity is captured before every suspension. A completion may mutate
/// composer state only while `isCurrent` still confirms that exact destination.
struct PromptComposerDestination: Equatable {
    /// Default-preserving so every existing destination keeps the behavior it
    /// had before First Mate opted into dictation Stop-to-send.
    var voicePolicy: PromptComposerVoicePolicy = .legacy
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
