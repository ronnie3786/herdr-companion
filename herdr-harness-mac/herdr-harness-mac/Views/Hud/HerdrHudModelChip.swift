import SwiftUI

struct HerdrHudModelChip: View {
    let currentSelectionID: String?
    let availableModels: [PiAvailableModel]
    let defaultModel: PiModelIdentity?
    let isLoading: Bool
    let errorMessage: String?
    let favorites: ModelFavoritesStore
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
        guard let defaultModel else { return "Default" }
        return "Default: \(defaultModel.displayName)"
    }

    private var selectedDisplayName: String {
        guard let currentSelectionID else { return "Default" }
        return availableModels.first(where: { $0.id == currentSelectionID })?.displayName ?? PiModelDisplayName.short(fullID: currentSelectionID)
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Text(selectedDisplayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .herdrFont(.caption2)
        }
        .herdrFont(.caption, weight: .medium)
        .foregroundStyle(HerdrTheme.mist)
        .padding(.horizontal, 4)
        .frame(minHeight: 30)
        .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

}
