import SwiftUI

/// The composer toolbar's model + effort pill.
struct PiComposerOptionsBar: View {
    let configuration: PiPromptComposerConfiguration
    let modelFavorites: ModelFavoritesStore

    var body: some View {
        PiModelEffortPill {
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
                },
                modelFavorites: modelFavorites,
                style: .segment
            )
        } effort: {
            PiThinkingLevelChip(
                currentLevel: configuration.thinkingLevel,
                isSetting: configuration.isSettingThinkingLevel,
                isEnabled: configuration.canSelectThinkingLevel,
                isInteractive: configuration.supportsThinkingMenu,
                selectLevel: { level in
                    Task { _ = await configuration.selectThinkingLevel(level) }
                },
                style: .segment
            )
        }
    }
}
