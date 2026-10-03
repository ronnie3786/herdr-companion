import SwiftUI

struct PRReviewAgentProfileEditor: View {
    private enum TeamSheet: String, Identifiable {
        case newTeam, editTeams
        var id: String { rawValue }
    }

    // Control characters never appear in team IDs or names, so these menu tags cannot collide.
    private static let newTeamTag = "\u{1}new-team"
    private static let editTeamsTag = "\u{1}edit-teams"

    let store: AgentRolesStore
    @Binding var role: AgentRole
    @State private var confirmsDelete = false
    @State private var teamSheet: TeamSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AgentRoleAvatarPicker(avatar: $role.avatar)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Team").herdrFont(.headline)
                    Picker("Team", selection: teamSelection) {
                        Text("No team").tag("")
                        if !store.teams.isEmpty {
                            Divider()
                            ForEach(store.teams) { team in Text(team.name).tag(team.id) }
                        }
                        Divider()
                        Text("New Team…").tag(Self.newTeamTag)
                        if store.supportsTeams { Text("Edit Teams…").tag(Self.editTeamsTag) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("agent-role-review-team")
                    Text(store.supportsTeams
                         ? "Agents on the same team can be selected together when starting a review."
                         : "Agents on the same team can be selected together when starting a review. Update the companion on \(store.selectedMachine?.name ?? "this computer") to rename or delete teams.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review prompt").herdrFont(.headline)
                    // A text editor, not a field, so Return starts a new line.
                    TextEditor(text: $role.reviewPrompt)
                        .herdrFont(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 200, idealHeight: 280)
                        .overlay(alignment: .topLeading) {
                            if role.reviewPrompt.isEmpty {
                                Text(AgentRole.defaultReviewPrompt)
                                    .herdrFont(.body)
                                    .foregroundStyle(HerdrTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // Matches the editor's padding plus its text inset.
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .background(HerdrTheme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.outline))
                        .accessibilityLabel("Review prompt")
                        .accessibilityIdentifier("agent-role-review-prompt")
                    Text("Leave blank to use the review shown above. {url} inserts the pull request link.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                Text("Uses the execution computer's default model. Choose skills in the Skills tab.")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                if !role.builtin {
                    Divider()
                    Button("Delete review agent…", role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("agent-role-delete")
                }
            }
            .herdrFont(.callout)
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!store.canEdit)
        }
        .sheet(item: $teamSheet) { sheet in
            switch sheet {
            case .newTeam: AgentRoleNewTeamSheet(store: store)
            case .editTeams: AgentRoleTeamsSheet(store: store)
            }
        }
        .confirmationDialog("Delete \(role.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Review Agent", role: .destructive, action: deleteRole)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This agent will no longer be available for new reviews. Existing reviews keep their reports.")
        }
    }

    /// The two trailing menu items open sheets instead of changing the agent's team.
    private var teamSelection: Binding<String> {
        Binding {
            let id = store.draftTeamID
            return store.teams.contains { $0.id == id } ? id : ""
        } set: { value in
            switch value {
            case Self.newTeamTag: teamSheet = .newTeam
            case Self.editTeamsTag: teamSheet = .editTeams
            default: store.assignTeam(value)
            }
        }
    }

    private func deleteRole() { Task { await store.deleteRole() } }
}
