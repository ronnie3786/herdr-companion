import SwiftUI

struct AgentsListView: View {
    @Bindable var model: HerdrAppModel
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        let sessions = sessions

        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    AgentsHeader(model: model)

                    WorkspaceSearchField(
                        text: $query,
                        placeholder: "Search agents",
                        clearAccessibilityLabel: "Clear agent search",
                        monospaced: false
                    )

                    HerdrSectionLabel(
                        title: "Recent Pi sessions",
                        detail: "\(sessions.count) shown",
                        monospaced: false
                    )

                    if sessions.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No Pi sessions" : "No matching agents",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(query.isEmpty
                                ? "Open the navigator to start a Pi chat in a workspace."
                                : "Search by agent, machine, workspace, tab, or status.")
                        )
                    } else {
                        ForEach(sessions) { session in
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
                            .accessibilityHint("Opens this agent session")
                            .contextMenu {
                                Button("Open workspace", systemImage: "folder") {
                                    selectWorkspace(session.workspace)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Agents")
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: agentStatuses, initial: true) { _, statuses in
            if let event = statusHapticTracker.observe(statuses) {
                hapticPulse.fire(event)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            statusHapticTracker.setSceneActive(
                phase == .active,
                isDemoMode: model.isDemoMode,
                statuses: agentStatuses
            )
        }
        // `refreshTick`, not `lastUpdated`: the tracker re-arms haptics on the
        // first server refresh after foregrounding, and that refresh is usually
        // boring — `lastUpdated` would not move and haptics would stay silent.
        .onChange(of: model.refreshTick) {
            statusHapticTracker.recordRefresh(statuses: agentStatuses)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private var sessions: [AgentSession] {
        AgentSession.recent(workspaces: model.workspaces, machines: model.machines, query: query)
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }
}
