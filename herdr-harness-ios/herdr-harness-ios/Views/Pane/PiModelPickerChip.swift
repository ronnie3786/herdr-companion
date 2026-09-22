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

    var body: some View {
        if isInteractive {
            Menu {
                if isLoading {
                    Text("Loading models…").disabled(true)
                } else if let errorMessage = errorMessage {
                    Text(errorMessage).disabled(true)
                    Button("Retry", action: retry)
                } else if availableModels.isEmpty {
                    Text("No models available").disabled(true)
                } else {
                    ForEach(groupedProviders, id: \.self) { provider in
                        Section(provider) {
                            ForEach(modelsByProvider[provider] ?? []) { candidate in
                                Button {
                                    selectModel(candidate)
                                } label: {
                                    Label(
                                        candidate.displayName,
                                        systemImage: isCurrent(candidate) ? "checkmark.circle.fill" : "cpu"
                                    )
                                }
                            }
                        }
                    }
                }
            } label: {
                controlLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-model")
            .composerLayoutMeasurement(id: "pi-chat-model", label: "Model: \(displayText)")
            .accessibilityLabel("Model: \(displayText)")
        } else if currentModel != nil {
            controlLabel
                .opacity(0.65)
                .accessibilityIdentifier("pi-chat-model")
                .composerLayoutMeasurement(id: "pi-chat-model", label: "Model: \(displayText)")
                .accessibilityLabel("Model: \(displayText)")
        }
    }

    private var controlLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isSetting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "cpu")
                    .font(.caption)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }

            Text(displayText)
                .font(.callout.bold())
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsTightening(true)
                .composerLayoutMeasurement(id: "pi-chat-model-value", label: displayText)

            if isInteractive {
                Image(systemName: "chevron.up.down")
                    .font(.caption)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isInteractive ? HerdrTheme.mauve : HerdrTheme.mist)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .opacity(isInteractive && !isEnabled ? 0.48 : 1)
    }

    private var displayText: String {
        if isLoading, currentModel == nil { return "Loading…" }
        return currentModel?.displayName ?? "Not reported"
    }

    private var modelsByProvider: [String: [PiAvailableModel]] {
        Dictionary(grouping: availableModels, by: \.provider)
    }

    private var groupedProviders: [String] {
        modelsByProvider.keys.sorted()
    }

    private func isCurrent(_ candidate: PiAvailableModel) -> Bool {
        currentModel?.provider == candidate.provider && currentModel?.id == candidate.modelID
    }
}

#Preview("Long synthetic model stays readable") {
    HStack {
        PiModelPickerChip(
            currentModel: PiModelIdentity(
                provider: "synthetic-provider",
                id: "synthetic-model-long",
                name: "Synthetic Runtime Model With A Long Name"
            ),
            availableModels: [],
            isLoading: false,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            errorMessage: nil,
            selectModel: { _ in },
            retry: { }
        )
        PiThinkingLevelChip(
            currentLevel: PiThinkingLevel.xhigh.rawValue,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            selectLevel: { _ in }
        )
    }
    .padding(.horizontal, 12)
    .frame(width: 375)
    .background(HerdrTheme.ink)
}
