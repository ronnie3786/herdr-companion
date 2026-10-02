import SwiftUI

struct PRReviewAgentPicker: View {
    let agents: [AgentRole]
    @Binding var selection: Set<String>
    var unavailableIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(PRReviewAgentSelection.groups(agents)) { group in
                PRReviewAgentPickerGroup(group: group, selection: $selection, unavailableIDs: unavailableIDs)
            }
            if agents.isEmpty {
                ContentUnavailableView("No review agents", systemImage: "person.crop.circle.badge.plus",
                    description: Text("Create an agent in Settings → Agent Roles → PR Review Agents."))
            }
        }
    }
}

private struct PRReviewAgentPickerGroup: View {
    @Environment(\.herdrFontScale) private var fontScale
    let group: PRReviewAgentGroup
    @Binding var selection: Set<String>
    let unavailableIDs: Set<String>
    private var availableIDs: Set<String> { Set(group.agents.map(\.id)).subtracting(unavailableIDs) }
    private var allSelected: Bool { !availableIDs.isEmpty && availableIDs.isSubset(of: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !group.name.isEmpty {
                Button(action: selectTeam) {
                    HStack {
                        Text(group.name).herdrFont(.headline)
                        Spacer()
                        Text(allSelected ? "Deselect team" : "Select team").herdrFont(.caption)
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .foregroundStyle(HerdrTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.herdrPlain)
                .disabled(availableIDs.isEmpty)
                .accessibilityLabel("\(allSelected ? "Deselect" : "Select") \(group.name)")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230 * fontScale.rawValue), spacing: 10)], spacing: 10) {
                ForEach(group.agents) { agent in
                    PRReviewAgentChoice(agent: agent, selected: selection.contains(agent.id),
                                        unavailable: unavailableIDs.contains(agent.id)) { toggle(agent.id) }
                }
            }
        }
    }

    private func selectTeam() { selection = PRReviewAgentSelection.toggling(availableIDs, in: selection) }
    private func toggle(_ id: String) { selection = PRReviewAgentSelection.toggling([id], in: selection) }
}

private struct PRReviewAgentChoice: View {
    let agent: AgentRole
    let selected: Bool
    let unavailable: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 12) {
                AgentRoleAvatarView(avatar: agent.avatar, size: 38, selected: selected)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).herdrFont(.callout, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(unavailable ? "Already running" : "\(agent.skillIds?.count ?? 0) skills")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? HerdrTheme.accent : HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .herdrCard(fill: selected ? HerdrTheme.accent.opacity(0.10) : HerdrTheme.cardFill,
                       outline: selected ? HerdrTheme.accent.opacity(0.5) : HerdrTheme.outline)
            .contentShape(RoundedRectangle(cornerRadius: HerdrTheme.Radius.card))
        }
        .buttonStyle(.herdrPlain)
        .disabled(unavailable)
        .accessibilityLabel(agent.name)
        .accessibilityValue(unavailable ? "Already running" : selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("pr-review-agent-choice-\(agent.id)")
    }
}
