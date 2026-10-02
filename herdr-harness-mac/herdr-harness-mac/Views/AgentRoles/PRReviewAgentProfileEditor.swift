import SwiftUI

struct PRReviewAgentProfileEditor: View {
    let store: AgentRolesStore
    @Binding var role: AgentRole
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AgentRoleAvatarPicker(avatar: $role.avatar)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Team").herdrFont(.headline)
                    TextField("Optional team name", text: $role.group)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agent-role-review-team")
                    Text("Agents with the same team name can be selected together when starting a review.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review prompt").herdrFont(.headline)
                    ZStack(alignment: .topLeading) {
                        TextField("Review prompt", text: $role.reviewPrompt, prompt: Text(""), axis: .vertical)
                            .lineLimit(8...16)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("agent-role-review-prompt")
                        if role.reviewPrompt.isEmpty {
                            Text(AgentRole.defaultReviewPrompt)
                                .foregroundStyle(HerdrTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                        .herdrFont(.body)
                        .padding(12)
                        .background(HerdrTheme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.outline))
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
        .confirmationDialog("Delete \(role.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Review Agent", role: .destructive, action: deleteRole)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This agent will no longer be available for new reviews. Existing reviews keep their reports.")
        }
    }

    private func deleteRole() { Task { await store.deleteRole() } }
}
