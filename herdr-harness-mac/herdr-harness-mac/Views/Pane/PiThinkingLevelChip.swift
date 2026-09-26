import SwiftUI

struct PiThinkingLevelChip: View {
    let currentLevel: String?
    let isSetting: Bool
    let isEnabled: Bool
    let isInteractive: Bool
    let selectLevel: (PiThinkingLevel) -> Void
    var style: ComposerChipStyle = .standalone

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
                .accessibilityIdentifier("pi-chat-thinking")
                .accessibilityLabel("Thinking level: \(displayText)")
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 4) {
            if isSetting {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(displayText)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if isInteractive {
                Image(systemName: "chevron.down")
                    .herdrFont(size: 10, weight: .semibold)
                    .foregroundStyle(HerdrTheme.iconTint)
            }
        }
        .composerChip(style)
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
