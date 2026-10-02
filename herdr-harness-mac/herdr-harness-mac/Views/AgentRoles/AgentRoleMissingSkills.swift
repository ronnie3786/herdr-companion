import SwiftUI

struct AgentRoleMissingSkills: View {
    let store: AgentRolesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unavailable on this Mac", systemImage: "exclamationmark.triangle")
                .herdrFont(.callout, weight: .semibold)
                .foregroundStyle(HerdrTheme.warning)
            Text("These selected skills are not in your local folders. Restore the folder to update their packages, or remove them from this role.")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            ForEach(store.missingIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(store.missingSkillName(id))
                        .herdrFont(.caption, monospaced: true)
                        .lineLimit(2)
                        .help(id)
                    Spacer(minLength: 0)
                    Button("Remove", systemImage: "minus.circle") { store.toggleSkill(id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(store.missingSkillName(id))")
                        .disabled(!store.canChangeSkills)
                }
            }
        }
        .padding(12)
        .background(HerdrTheme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 12)
        .accessibilityIdentifier("agent-role-missing-skills")
    }
}
