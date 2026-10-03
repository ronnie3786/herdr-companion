import SwiftUI

/// Renames, deletes, and adds saved PR review teams. Membership follows the
/// team ID, so a rename keeps every agent on the team.
struct AgentRoleTeamsSheet: View {
    let store: AgentRolesStore
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [String: String] = [:]
    @State private var newName = ""
    @State private var deleting: AgentRoleTeam?

    private var newNameProblem: String? { newName.isEmpty ? nil : store.teamNameProblem(newName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Teams").herdrFont(.title2, weight: .semibold)
                Text("Teams on \(store.selectedMachine?.name ?? "this computer") let you select several review agents at once. Agents stay on a team when you rename it.")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.teams) { team in row(team) }
                    if store.teams.isEmpty {
                        ContentUnavailableView("No teams yet", systemImage: "person.3",
                            description: Text("Add a team below, then choose it for each review agent."))
                            .padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                TextField("New team name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityIdentifier("agent-role-teams-new-name")
                Button("Add Team", systemImage: "plus", action: add)
                    .disabled(newName.isEmpty || newNameProblem != nil || !store.canEditTeams)
            }
            if let message = newNameProblem ?? store.teamErrorMessage {
                Text(message).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.isSavingTeams { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.controlAccent)
        .onAppear { store.clearTeamError() }
        .confirmationDialog("Delete \(deleting?.name ?? "team")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Team", role: .destructive) {
                guard let team = deleting else { return }
                Task { await store.deleteTeam(team.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = deleting.map { store.memberCount(ofTeam: $0.id) } ?? 0
            Text(count == 0 ? "No review agents are on this team."
                 : "\(count) review \(count == 1 ? "agent" : "agents") will have no team. Existing reviews keep their reports.")
        }
        .accessibilityIdentifier("agent-role-teams-sheet")
    }

    private func row(_ team: AgentRoleTeam) -> some View {
        let edited = edits[team.id] ?? team.name
        let changed = edited != team.name
        let problem = changed ? store.teamNameProblem(edited, renaming: team.id) : nil
        let count = store.memberCount(ofTeam: team.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Team name", text: Binding(get: { edits[team.id] ?? team.name }, set: { edits[team.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rename(team) }
                    .accessibilityIdentifier("agent-role-team-name-\(team.id)")
                Text("\(count) \(count == 1 ? "agent" : "agents")")
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize()
                if changed {
                    Button("Rename") { rename(team) }
                        .disabled(problem != nil || !store.canEditTeams)
                }
                Button("Delete \(team.name)", systemImage: "trash") { deleting = team }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!store.canEditTeams)
                    .help("Delete team")
            }
            if let problem {
                Text(problem).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
            }
        }
        .padding(12)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
    }

    private func rename(_ team: AgentRoleTeam) {
        guard let name = edits[team.id], name != team.name, store.teamNameProblem(name, renaming: team.id) == nil else { return }
        Task { if await store.renameTeam(team.id, to: name) { edits[team.id] = nil } }
    }

    private func add() {
        guard !newName.isEmpty, newNameProblem == nil else { return }
        Task { if await store.createTeam(named: newName, assigningDraft: false) { newName = "" } }
    }
}
