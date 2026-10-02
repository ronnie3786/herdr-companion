import SwiftUI

struct AgentRolesRail: View {
    let store: AgentRolesStore
    let select: (String) -> Void
    let newRole: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("BUILT-IN")
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.top, 8)
                ForEach(store.roles.filter(\.builtin)) { role in
                    AgentRoleRow(role: role, selected: store.draft?.id == role.id) { select(role.id) }
                }
                Text("CUSTOM")
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.top, 18)
                ForEach(store.roles.filter { !$0.builtin }) { role in
                    AgentRoleRow(role: role, selected: store.draft?.id == role.id) { select(role.id) }
                }
                Button("New role", systemImage: "plus", action: newRole)
                    .buttonStyle(.borderless)
                    .padding(8)
                    .accessibilityIdentifier("agent-roles-new")
                if store.roles.allSatisfy(\.builtin) {
                    Text("Add a specialist for your team's work.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.horizontal, 8)
                }
            }
            .padding(8)
        }
        .frame(width: 178)
        .frame(maxHeight: .infinity)
        .background(HerdrTheme.railBackground.opacity(0.6))
        .disabled(store.isSaving)
        .accessibilityLabel("Agent roles")
    }
}
