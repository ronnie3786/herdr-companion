import SwiftUI

struct AgentWorkspaceSection: View {
    @Bindable var model: HerdrAppModel
    let group: AgentWorkspaceGroup
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            AgentWorkspaceHeading(group: group)
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
                        .accessibilityHint("Opens this \(session.agentName) agent in \(group.workspace.label), tab \(tab.name), on \(group.machineName)")
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
                    .padding(.top, 4)
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Tab: \(tab.name), \(tab.sessions.count) agents")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("agent-tab-\(tab.id)")
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}
