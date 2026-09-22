import SwiftUI

#if DEBUG
/// Synthetic, server-free host for UI interaction coverage of the compact
/// composer pickers. It is reachable only through the UI-test launch argument.
struct PiOptionsUITestFixtureView: View {
    private let models = [
        PiAvailableModel(
            provider: "sample-provider",
            modelID: "sample-pro",
            name: "Sample Pro",
            reasoning: true,
            contextWindow: 128_000
        ),
        PiAvailableModel(
            provider: "sample-provider",
            modelID: "sample-standard",
            name: "Sample Standard",
            reasoning: true,
            contextWindow: 128_000
        ),
    ]

    @State private var currentModel = PiModelIdentity(
        provider: "sample-provider",
        id: "sample-pro",
        name: "Sample Pro"
    )
    @State private var thinkingLevel = PiThinkingLevel.high

    var body: some View {
        VStack {
            PiComposerOptionsLayout(isAccessibilitySize: false) {
                PiModelPickerChip(
                    currentModel: currentModel,
                    availableModels: models,
                    isLoading: false,
                    isSetting: false,
                    isEnabled: true,
                    isInteractive: true,
                    errorMessage: nil,
                    selectModel: selectModel,
                    retry: { }
                )

                PiThinkingLevelChip(
                    currentLevel: thinkingLevel.rawValue,
                    isSetting: false,
                    isEnabled: true,
                    isInteractive: true,
                    selectLevel: { thinkingLevel = $0 }
                )
            }
            .padding(.horizontal, 12)

            Spacer()
        }
        .background(HerdrTheme.ink.ignoresSafeArea())
    }

    private func selectModel(_ candidate: PiAvailableModel) {
        currentModel = PiModelIdentity(
            provider: candidate.provider,
            id: candidate.modelID,
            name: candidate.displayName
        )
    }
}
#endif
