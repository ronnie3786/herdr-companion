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
        VStack(alignment: .leading, spacing: 1) {
            Text("Thinking")
                .font(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isSetting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "brain")
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
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isInteractive ? HerdrTheme.mauve : HerdrTheme.mist)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
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
