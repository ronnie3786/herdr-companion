import SwiftUI

struct HerdrHudModelChip: View {
    let currentSelectionID: String?
    let availableModels: [PiAvailableModel]
    let defaultModel: PiModelIdentity?
    let isLoading: Bool
    let errorMessage: String?
    let favorites: ModelFavoritesStore
    /// What the automatic choice is called for this composer. New chats show
    /// "Machine default"; existing conversations keep the legacy wording.
    var defaultChoiceTitle: String = "Default"
    let selectModel: (PiAvailableModel?) -> Void
    let retry: () -> Void

    var body: some View {
        Menu {
            Button {
                selectModel(nil)
            } label: {
                Label(defaultMenuTitle, systemImage: currentSelectionID == nil ? "checkmark.circle.fill" : "cpu")
            }

            if isLoading {
                Text("Loading models…").disabled(true)
            } else if let errorMessage {
                Text(errorMessage).disabled(true)
                Button("Retry", action: retry)
            } else if availableModels.isEmpty {
                Text("No models available").disabled(true)
            } else {
                PiModelMenuContent(
                    models: availableModels,
                    favorites: favorites,
                    isSelected: { $0.id == currentSelectionID },
                    select: { selectModel($0) }
                )
            }
        } label: {
            chipLabel
        }
        .piChipMenu()
        .accessibilityIdentifier("hud-model")
        .accessibilityLabel("Model: \(selectedDisplayName)")
    }

    private var defaultMenuTitle: String {
        guard let defaultModel else { return defaultChoiceTitle }
        return "\(defaultChoiceTitle): \(defaultModel.displayName)"
    }

    private var selectedDisplayName: String {
        guard let currentSelectionID else { return defaultChoiceTitle }
        return availableModels.first(where: { $0.id == currentSelectionID })?.displayName ?? PiModelDisplayName.short(fullID: currentSelectionID)
    }

    /// The model half of the composer's model + effort pill.
    private var chipLabel: some View {
        HStack(spacing: 5) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "bolt")
                    .herdrFont(size: 13)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            Text(selectedDisplayName)
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }
}
