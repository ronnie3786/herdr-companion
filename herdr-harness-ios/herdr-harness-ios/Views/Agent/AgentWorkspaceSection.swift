import SwiftUI

struct AgentWorkspaceSection: View {
    @Bindable var model: HerdrAppModel
    let group: AgentWorkspaceGroup
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(group.workspace.label)
                    .font(.title2.bold())
                    .foregroundStyle(HerdrTheme.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("agent-workspace-\(group.id)")
                Label(group.machineName, systemImage: "desktopcomputer")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityLabel("Machine: \(group.machineName)")
            }
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu {
                Button("Open workspace", systemImage: "folder") { selectWorkspace(group.workspace) }
            }

            ForEach(group.tabs) { tab in
                Section {
                    ForEach(tab.sessions) { session in
                        Button {
                            selectPane(session.pane)
                        } label: {
                            AgentSessionCard(
                                session: session,
                                connectionState: model.connectionState(forMachine: session.pane.machineID),
                                isUnread: model.unreadPaneIDs.contains(session.id),
                                isStarred: model.starredChatIDs.contains(session.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-card-\(session.id)")
                        .accessibilityHint("Opens this agent in \(group.workspace.label), tab \(tab.name), on \(group.machineName)")
                        .contextMenu {
                            Button("Open workspace", systemImage: "folder") { selectWorkspace(group.workspace) }
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Label(tab.name, systemImage: "rectangle.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(tab.sessions.count)")
                            .font(.caption)
                    }
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Tab: \(tab.name), \(tab.sessions.count) agents")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("agent-tab-\(tab.id)")
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}
