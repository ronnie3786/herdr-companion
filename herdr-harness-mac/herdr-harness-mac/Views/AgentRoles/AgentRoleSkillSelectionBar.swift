import SwiftUI

struct AgentRoleSkillSelectionBar: View {
    let store: AgentRolesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(store.selectedIDs.count) selected")
                    .herdrFont(.callout, weight: .semibold)
                ProgressView(value: Double(store.selectedTokens), total: Double(max(1, store.allTokens)))
                    .frame(maxWidth: 100)
                    .accessibilityLabel("Skill prompt tokens")
                    .accessibilityValue("\(store.selectedTokens) of \(store.allTokens)")
                Text("~\(store.selectedTokens.formatted()) tokens")
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            Text(store.missingIDs.isEmpty
                ? "Save copies packages to \(store.selectedMachine?.name ?? "the execution computer"). Update Copies refreshes them after local file changes. Clear allows no skills."
                : "Missing local skills keep any existing saved copy. Token estimate excludes them. Copies on other computers are unchanged.")
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(HerdrTheme.railBackground.opacity(0.6))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var actions: some View {
        Menu("Copy from role…") {
            ForEach(store.roles.filter { !$0.locked && $0.id != store.draft?.id && $0.skillIds != nil }) { role in
                Button(role.name) { store.copySkills(from: role) }
            }
        }
        .disabled(!store.canChangeSkills || !store.roles.contains { !$0.locked && $0.id != store.draft?.id && $0.skillIds != nil })
        .fixedSize()
        Button("Select shown", action: store.selectShown)
            .disabled(!store.canChangeSkills || store.filteredSkills.isEmpty)
        Button("Clear", action: store.clearSkills)
            .disabled(!store.canChangeSkills || store.selectedIDs.isEmpty)
        Button("Update Copies") { Task { await store.updateCopies() } }
            .disabled(!store.canUpdateCopies)
            .help("Copy the selected packages from this Mac again, without changing the role. Updates only the selected execution computer.")
            .accessibilityIdentifier("agent-role-update-copies")
    }
}
