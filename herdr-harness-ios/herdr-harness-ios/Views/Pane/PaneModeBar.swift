import SwiftUI

struct PaneModeBar: View {
    @Binding var selection: PaneDetailMode
    let supportsChat: Bool
    let gitAvailability: PaneGitAvailability

    var body: some View {
        HStack(spacing: 3) {
            modeButton(.chat, isEnabled: supportsChat)
            modeButton(.git, isEnabled: gitAvailability == .available)
            modeButton(.terminal, isEnabled: true)
        }
        .padding(3)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.subtleSeparator, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-mode-bar")
    }

    private func modeButton(_ mode: PaneDetailMode, isEnabled: Bool) -> some View {
        Button {
            selection = mode
        } label: {
            HStack(spacing: 5) {
                Text(mode.label)
                    .font(.subheadline.weight(selection == mode ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if mode == .git, gitAvailability == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if mode == .git, gitAvailability == .unavailable {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selection == mode ? HerdrTheme.text : HerdrTheme.mist)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selection == mode ? HerdrTheme.selection : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius - 2)
                    .strokeBorder(
                        selection == mode ? HerdrTheme.separator : .clear,
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius - 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityLabel(mode.label)
        .accessibilityValue(selection == mode ? "Selected" : "Not selected")
        .accessibilityHint(accessibilityHint(for: mode, isEnabled: isEnabled))
        .accessibilityIdentifier("pane-mode-\(mode.rawValue)")
    }

    private func accessibilityHint(for mode: PaneDetailMode, isEnabled: Bool) -> String {
        guard !isEnabled else { return "Shows the \(mode.label) view for this pane" }
        switch mode {
        case .chat:
            return "Native chat is unavailable for this shell"
        case .git where gitAvailability == .checking:
            return "Checking this workspace for a Git repository"
        case .git:
            return "No Git repository is available for this workspace"
        case .terminal, .skills:
            return ""
        }
    }
}
