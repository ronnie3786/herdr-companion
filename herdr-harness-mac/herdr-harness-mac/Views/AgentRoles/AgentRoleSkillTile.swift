import SwiftUI

struct AgentRoleSkillTile: View {
    let skill: AgentRoleSkill
    let sourceName: String
    let selected: Bool
    let enabled: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Text(skill.name)
                        .herdrFont(.callout, monospaced: true, weight: .medium)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? HerdrTheme.accent : HerdrTheme.secondaryText)
                        .opacity(enabled ? 1 : 0.4)
                        .accessibilityHidden(true)
                }
                Text(skill.description)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(sourceName)
                        .herdrFont(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(HerdrTheme.chipFill, in: Capsule())
                    Spacer(minLength: 0)
                    Text("~\(max(0, skill.estimatedTokens).formatted()) tokens")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.top, 3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? HerdrTheme.accent.opacity(0.10) : HerdrTheme.inkFill(hovered && enabled ? 0.07 : 0.035),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                selected ? HerdrTheme.accent.opacity(0.65) : HerdrTheme.separator, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(AgentRoleSkillTileButtonStyle())
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help("\(skill.name)\n\(skill.description)\n\(skill.path)")
        .accessibilityLabel(skill.name)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("\(skill.description). \(sourceName). Approximately \(max(0, skill.estimatedTokens)) tokens.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-role-skill-\(skill.id)")
    }
}
