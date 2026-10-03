import SwiftUI

/// Names a new team and puts the review agent being edited on it.
struct AgentRoleNewTeamSheet: View {
    let store: AgentRolesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var problem: String? { name.isEmpty ? nil : store.teamNameProblem(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Team").herdrFont(.title3, weight: .semibold)
                Text(store.supportsTeams
                     ? "The team is saved on \(store.selectedMachine?.name ?? "the execution computer") and this agent joins it."
                     : "This agent joins the team when you save it.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Team name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
                .accessibilityIdentifier("agent-role-new-team-name")
            if let message = problem ?? store.teamErrorMessage {
                Text(message).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.isSavingTeams { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Team", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || problem != nil || store.isSaving)
                    .accessibilityIdentifier("agent-role-create-team")
            }
        }
        .padding(20)
        .frame(width: 380)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.controlAccent)
        .onAppear {
            store.clearTeamError()
            focused = true
        }
    }

    private func create() {
        guard !name.isEmpty, problem == nil else { return }
        Task { if await store.createTeam(named: name) { dismiss() } }
    }
}
