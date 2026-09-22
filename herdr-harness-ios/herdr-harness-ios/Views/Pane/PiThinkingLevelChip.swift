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
                        Label(
                            level.displayName,
                            systemImage: isCurrent(level) ? "checkmark.circle.fill" : "brain"
                        )
                    }
                }
            } label: {
                controlLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-thinking")
            .composerLayoutMeasurement(id: "pi-chat-thinking", label: "Thinking level: \(displayText)")
            .accessibilityLabel("Thinking level: \(displayText)")
        } else if currentLevel != nil {
            controlLabel
                .opacity(0.65)
                .accessibilityIdentifier("pi-chat-thinking")
                .composerLayoutMeasurement(id: "pi-chat-thinking", label: "Thinking level: \(displayText)")
                .accessibilityLabel("Thinking level: \(displayText)")
        }
    }

    private var controlLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isSetting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "brain")
                    .font(.caption)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }

            Text(displayText)
                .font(.callout.bold())
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .composerLayoutMeasurement(id: "pi-chat-thinking-value", label: displayText)

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
        guard let currentLevel else { return "Not reported" }
        return PiThinkingLevel(rawValue: currentLevel)?.displayName ?? currentLevel
    }

    private func isCurrent(_ level: PiThinkingLevel) -> Bool {
        currentLevel == level.rawValue
    }
}
