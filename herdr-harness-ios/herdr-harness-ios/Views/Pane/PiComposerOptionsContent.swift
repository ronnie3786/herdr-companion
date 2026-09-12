import SwiftUI

/// Supplies stable Model, Thinking, and optional audio positions to
/// `PiComposerOptionsLayout`; picker APIs and capability gates stay unchanged.
struct PiComposerOptionsContent: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?
    let isAccessibilitySize: Bool

    var body: some View {
        PiComposerOptionsLayout(isAccessibilitySize: isAccessibilitySize) {
            PiModelPickerChip(
                currentModel: configuration.currentModel,
                availableModels: configuration.availableModels,
                isLoading: configuration.isLoadingModels,
                isSetting: configuration.isSettingModel,
                isEnabled: configuration.canSelectModel,
                isInteractive: configuration.supportsModelMenu,
                errorMessage: configuration.modelCatalogError,
                selectModel: { candidate in
                    Task { _ = await configuration.selectModel(candidate) }
                },
                retry: {
                    Task { await configuration.retryLoadModels() }
                }
            )

            PiThinkingLevelChip(
                currentLevel: configuration.thinkingLevel,
                isSetting: configuration.isSettingThinkingLevel,
                isEnabled: configuration.canSelectThinkingLevel,
                isInteractive: configuration.supportsThinkingMenu,
                selectLevel: { level in
                    Task { _ = await configuration.selectThinkingLevel(level) }
                }
            )

            if let responseAudioPlayer,
               responseAudioPlayer.isVisible,
               let activateResponseAudio {
                ResponseAudioControlsView(
                    player: responseAudioPlayer,
                    showsTitles: false,
                    activate: activateResponseAudio
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
