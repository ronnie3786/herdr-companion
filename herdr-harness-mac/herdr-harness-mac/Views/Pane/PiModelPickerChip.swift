import SwiftUI

struct PiModelPickerChip: View {
    let currentModel: PiModelIdentity?
    let availableModels: [PiAvailableModel]
    let isLoading: Bool
    let isSetting: Bool
    let isEnabled: Bool
    let isInteractive: Bool
    let errorMessage: String?
    let selectModel: (PiAvailableModel) -> Void
    let retry: () -> Void
    let modelFavorites: ModelFavoritesStore
    /// `.standalone` draws its own 26pt pill; `.segment` is the model half of
    /// `PiModelEffortPill`.
    var style: ComposerChipStyle = .standalone

    var body: some View {
        if isInteractive {
            Menu {
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
                        favorites: modelFavorites,
                        isSelected: isCurrent,
                        select: selectModel
                    )
                }
            } label: {
                chipLabel
            }
            .piChipMenu()
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-model")
            .accessibilityLabel("Model: \(currentModel?.displayName ?? "unknown")")
        } else if currentModel != nil {
            chipLabel
                .accessibilityIdentifier("pi-chat-model")
                .accessibilityLabel("Model: \(currentModel?.displayName ?? "unknown")")
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 4) {
            if isSetting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "bolt")
                    .herdrFont(size: 12)
                    .accessibilityHidden(true)
            }
            Text(currentModel?.displayName ?? "model")
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if isInteractive, style == .standalone {
                Image(systemName: "chevron.down")
                    .herdrFont(size: 10, weight: .semibold)
                    .foregroundStyle(HerdrTheme.iconTint)
            }
        }
        .foregroundStyle(isInteractive ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
        .composerChip(style)
        .opacity(isInteractive && !isEnabled ? 0.45 : 1)
    }

    private func isCurrent(_ candidate: PiAvailableModel) -> Bool {
        currentModel?.provider == candidate.provider && currentModel?.id == candidate.modelID
    }
}

#Preview("Long model name stays one line") {
    HStack {
        PiModelPickerChip(
            currentModel: PiModelIdentity(
                provider: "anthropic",
                id: "claude-sonnet-4-5-20250929",
                name: "claude-sonnet-4-5-20250929"
            ),
            availableModels: [],
            isLoading: false,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            errorMessage: nil,
            selectModel: { _ in },
            retry: {},
            modelFavorites: ModelFavoritesStore()
        )
        PiThinkingLevelChip(
            currentLevel: PiThinkingLevel.xhigh.rawValue,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            selectLevel: { _ in }
        )
        Spacer()
    }
    .padding(.horizontal, 12)
    .frame(width: 375)
    .background(HerdrTheme.ink)
}

/// How a composer chip draws itself: its own 26pt pill, or one half of the
/// shared model + effort pill.
enum ComposerChipStyle: Equatable {
    case standalone, segment
}

extension View {
    /// A 26pt pill on a 10% ink wash, with a 28pt hit area; segments leave
    /// the pill to their container.
    func composerChip(_ style: ComposerChipStyle) -> some View {
        padding(.horizontal, style == .standalone ? 6 : 3)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .background {
                if style == .standalone {
                    RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                        .fill(HerdrTheme.selectedFill)
                        .frame(height: HerdrTheme.ControlHeight.regular)
                }
            }
            .contentShape(Rectangle())
    }
}

/// MonoCode's model + effort pill: "⚡ Claude Opus 5 High ⌄" as one 26pt
/// pill with two menus, so each keeps its own identifier and confirmation.
struct PiModelEffortPill<Model: View, Effort: View>: View {
    @ViewBuilder let model: () -> Model
    @ViewBuilder let effort: () -> Effort

    var body: some View {
        HStack(spacing: 0) {
            model()
            effort()
        }
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                .fill(HerdrTheme.selectedFill)
                .frame(height: HerdrTheme.ControlHeight.regular)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
