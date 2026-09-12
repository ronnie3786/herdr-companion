import SwiftUI

struct PiComposerOptionsBar: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            PiComposerOptionsRow(
                configuration: configuration,
                responseAudioPlayer: responseAudioPlayer,
                showsAudioTitles: true,
                activateResponseAudio: activateResponseAudio
            )
            PiComposerOptionsColumn(
                configuration: configuration,
                responseAudioPlayer: responseAudioPlayer,
                activateResponseAudio: activateResponseAudio
            )
        }
    }
}

private struct PiComposerOptionsRow: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let showsAudioTitles: Bool
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
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
            .frame(minWidth: 132)
            .layoutPriority(1)

            PiThinkingLevelChip(
                currentLevel: configuration.thinkingLevel,
                isSetting: configuration.isSettingThinkingLevel,
                isEnabled: configuration.canSelectThinkingLevel,
                isInteractive: configuration.supportsThinkingMenu,
                selectLevel: { level in
                    Task { _ = await configuration.selectThinkingLevel(level) }
                }
            )

            if let responseAudioPlayer, let activateResponseAudio {
                Spacer(minLength: 0)
                ResponseAudioControlsView(
                    player: responseAudioPlayer,
                    showsTitles: showsAudioTitles,
                    activate: activateResponseAudio
                )
            }
        }
    }
}

private struct PiComposerOptionsColumn: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if let responseAudioPlayer, let activateResponseAudio {
                HStack {
                    Spacer(minLength: 0)
                    ResponseAudioControlsView(
                        player: responseAudioPlayer,
                        showsTitles: false,
                        activate: activateResponseAudio
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
