import SwiftUI

struct AgentRolesRail: View {
    let store: AgentRolesStore
    let select: (String) -> Void
    let newRole: () -> Void
    let newPRReviewRole: () -> Void
    @State private var showsPRReviewAgents = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("First Mate roles")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.horizontal, 8).padding(.top, 8)
                    ForEach(store.workerRoles.filter(\.builtin)) { role in
                        AgentRoleRow(role: role, selected: store.draft?.id == role.id) { select(role.id) }
                    }
                    Text("Custom roles")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .padding(.horizontal, 8).padding(.top, 18)
                    ForEach(store.workerRoles.filter { !$0.builtin }) { role in
                        AgentRoleRow(role: role, selected: store.draft?.id == role.id) { select(role.id) }
                    }
                    Button("New role", systemImage: "plus", action: newRole)
                        .buttonStyle(.borderless)
                        .padding(8)
                        .accessibilityIdentifier("agent-roles-new")
                    if store.workerRoles.allSatisfy(\.builtin) {
                        Text("Add a specialist for your team's work.")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(8)
            }
            Divider()
            DisclosureGroup(isExpanded: $showsPRReviewAgents) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.prReviewRoles) { role in
                            AgentRoleRow(role: role, selected: store.draft?.id == role.id) { select(role.id) }
                        }
                        Button("New review agent", systemImage: "plus", action: newPRReviewRole)
                            .buttonStyle(.borderless)
                            .herdrFont(.callout)
                            .padding(.vertical, 8)
                            .disabled(!store.canCreatePRReviewRole)
                            .accessibilityIdentifier("agent-roles-new-pr-review")
                        if !store.supportsPRReviewAgents {
                            Text("Update this companion to configure review agents.")
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } label: {
                Text("PR Review Agents")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            .padding(10)
            .accessibilityIdentifier("agent-roles-pr-review-section")
        }
        .frame(width: 194)
        .frame(maxHeight: .infinity)
        .background(HerdrTheme.inkFill(0.015))
        .disabled(store.isSaving || store.isImporting || store.requiresConnectionReload)
        .accessibilityLabel("Agent roles")
        .onAppear(perform: revealSelectedReviewAgent)
        .onChange(of: store.draft?.id) { _, _ in revealSelectedReviewAgent() }
        .onChange(of: store.selectedMachineID) { _, _ in
            showsPRReviewAgents = store.draft?.isPRReview == true
        }
    }

    private func revealSelectedReviewAgent() {
        if store.draft?.isPRReview == true { showsPRReviewAgents = true }
    }
}
