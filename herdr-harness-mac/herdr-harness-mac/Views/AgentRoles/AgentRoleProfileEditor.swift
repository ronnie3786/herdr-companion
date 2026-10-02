import SwiftUI

struct AgentRoleProfileEditor: View {
    let store: AgentRolesStore
    @Binding var role: AgentRole
    @State private var showsPrompt = false
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When to use this agent").herdrFont(.headline)
                    Text("Second Mate reads this when choosing a role for a task.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    TextField("Describe the work this role is suited for…", text: $role.whenToUse, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agent-role-when-to-use")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("System prompt").herdrFont(.headline)
                    Text("Optional instructions added to new sessions in this role. Blank uses the existing role behavior.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    if showsPrompt || !role.systemPrompt.isEmpty {
                        TextEditor(text: $role.systemPrompt)
                            .herdrFont(.body, monospaced: true)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 150)
                            .background(HerdrTheme.ink.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.separator))
                            .accessibilityLabel("System prompt")
                            .accessibilityIdentifier("agent-role-system-prompt")
                    } else {
                        Button("Add system prompt", systemImage: "plus") { showsPrompt = true }
                            .buttonStyle(.bordered)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delegation").herdrFont(.headline)
                    Toggle("Allow this role to delegate tasks", isOn: $role.allowDelegation)
                        .accessibilityIdentifier("agent-role-delegation")
                    Text("Existing First Mate limits still apply. Enabling delegation does not grant extra tool permissions.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                if !role.builtin {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Model profile", selection: $role.modelProfile) {
                            Text("Execution").tag("execution")
                            Text("Planning").tag("planning")
                            Text("Architect").tag("architect")
                            Text("Research Scout").tag("research_scout")
                        }
                        .accessibilityIdentifier("agent-role-model-profile")
                        Text("Uses the selected computer's existing model and thinking settings for this profile.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }
                    Divider()
                    Button("Delete role…", role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("agent-role-delete")
                }
            }
            .herdrFont(.callout)
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!store.canEdit)
        }
        .confirmationDialog("Delete \(role.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Role", role: .destructive) { Task { await store.deleteRole() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New tasks will no longer be able to choose this role. Existing sessions keep their current configuration.")
        }
    }
}
