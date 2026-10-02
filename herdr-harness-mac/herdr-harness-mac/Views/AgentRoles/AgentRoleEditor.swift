import SwiftUI

struct AgentRoleEditor: View {
    enum Tab: String, CaseIterable, Identifiable {
        case profile = "Profile", skills = "Skills"
        var id: String { rawValue }
    }

    @Bindable var store: AgentRolesStore
    @Binding var role: AgentRole
    @State private var tab = Tab.profile

    init(store: AgentRolesStore, role: Binding<AgentRole>, initialTab: Tab = .profile) {
        self.store = store
        _role = role
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: role.locked ? "lock.shield" : "person.fill")
                    .herdrFont(.title2)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(HerdrTheme.elevated, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Role name", text: $role.name)
                        .textFieldStyle(.plain)
                        .herdrFont(.title3, weight: .semibold)
                        .disabled(!store.canEdit)
                        .accessibilityIdentifier("agent-role-name")
                    Text(role.locked ? "System role · Always restricted" : role.builtin ? "Built-in role" : "Custom role")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            Picker("Role settings", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            Divider()
            if role.locked {
                ContentUnavailableView("Recovery stays restricted", systemImage: "lock.shield",
                    description: Text("Recovery Advisor always runs without skills or delegation. Its system role cannot be edited."))
            } else {
                switch tab {
                case .profile: AgentRoleProfileEditor(store: store, role: $role)
                case .skills: AgentRoleSkillsView(store: store)
                }
                AgentRoleSaveBar(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agent-role-editor")
    }
}
