import SwiftUI

struct PiThinkingLevelChip: View {
    let currentLevel: String?
    let isSetting: Bool
    let isEnabled: Bool
    let isInteractive: Bool
    let selectLevel: (PiThinkingLevel) -> Void

    var body: some View {
        if isInteractive {
            Menu {
                ForEach(PiThinkingLevel.allCases, id: \.self) { level in
                    Button {
                        selectLevel(level)
                    } label: {
                        HStack {
                            Text(level.displayName)
                            if isCurrent(level) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                controlLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-thinking")
            .composerLayoutMeasurement(id: "pi-chat-thinking", label: accessibilityLabel)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Chooses the thinking level for the next message.")
        } else if currentLevel != nil {
            controlLabel
                .opacity(0.65)
                .accessibilityIdentifier("pi-chat-thinking")
                .composerLayoutMeasurement(id: "pi-chat-thinking", label: accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var controlLabel: some View {
        Text(visibleText)
            .font(.footnote)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isInteractive ? HerdrTheme.mauve : HerdrTheme.mist)
            .composerLayoutMeasurement(id: "pi-chat-thinking-value", label: visibleText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .opacity(isInteractive && !isEnabled ? 0.48 : 1)
    }

    private var visibleText: String {
        isSetting ? "Setting…" : displayText
    }

    private var accessibilityLabel: String {
        isSetting ? "Thinking level: \(displayText), setting" : "Thinking level: \(displayText)"
    }

    private var displayText: String {
        guard let currentLevel else { return "Not reported" }
        return PiThinkingLevel(rawValue: currentLevel)?.displayName ?? currentLevel
    }

    private func isCurrent(_ level: PiThinkingLevel) -> Bool {
        currentLevel == level.rawValue
    }
}
