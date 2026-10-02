import SwiftUI

struct AgentRoleEditor: View {
    enum Tab: String, CaseIterable, Identifiable {
        case profile = "Profile", skills = "Skills"
        var id: String { rawValue }
    }

    @Bindable var store: AgentRolesStore
    @Binding var role: AgentRole
    let showSources: () -> Void
    @State private var tab = Tab.profile

    init(store: AgentRolesStore, role: Binding<AgentRole>, initialTab: Tab = .profile, showSources: @escaping () -> Void = {}) {
        self.store = store
        self.showSources = showSources
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
                    .background(HerdrTheme.firstMateAvatarFill, in: Circle())
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
                Spacer(minLength: 8)
                Picker("Role settings", selection: $tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .tint(HerdrTheme.controlAccent)
                .labelsHidden()
                .frame(width: 148)
            }
            .padding(18)
            Divider()
            if role.locked {
                ContentUnavailableView("Recovery stays restricted", systemImage: "lock.shield",
                    description: Text("Recovery Advisor always runs without skills or delegation. Its system role cannot be edited."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .profile: AgentRoleProfileEditor(store: store, role: $role)
                case .skills: AgentRoleSkillsView(store: store, showSources: showSources)
                }
                AgentRoleSaveBar(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agent-role-editor")
    }
}
