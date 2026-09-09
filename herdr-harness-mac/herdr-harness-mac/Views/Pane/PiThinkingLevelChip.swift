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
                chipLabel
            }
            .piChipMenu()
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-thinking")
            .accessibilityLabel("Thinking level: \(displayText)")
        } else if currentLevel != nil {
            chipLabel
                .opacity(0.6)
                .accessibilityIdentifier("pi-chat-thinking")
                .accessibilityLabel("Thinking level: \(displayText)")
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 6) {
            if isSetting {
                ProgressView()
                    .controlSize(.small)
            }
            Text(displayText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if isInteractive {
                Image(systemName: "chevron.down")
                    .herdrFont(.caption2)
            }
        }
        .herdrFont(.caption, weight: .medium)
        .foregroundStyle(isInteractive ? HerdrTheme.mist : HerdrTheme.muted)
        .padding(.horizontal, 4)
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .opacity(isInteractive && !isEnabled ? 0.45 : 1)
    }

    private var displayText: String {
        guard let currentLevel else { return "thinking" }
        return PiThinkingLevel(rawValue: currentLevel)?.displayName ?? currentLevel
    }

    private func isCurrent(_ level: PiThinkingLevel) -> Bool {
        currentLevel == level.rawValue
    }
}
