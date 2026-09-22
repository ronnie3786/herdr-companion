import Foundation

/// Destination-neutral operations for the shared Mac prompt composer.
///
/// The identity is captured before every suspension. A completion may mutate
/// composer state only while `isCurrent` still confirms that exact destination.
struct PromptComposerDestination: Equatable {
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
    }
}

struct PromptComposerPaneContext {
    let model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
}
