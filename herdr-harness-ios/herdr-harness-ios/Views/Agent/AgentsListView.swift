import SwiftUI

struct AgentsListView: View {
    @Bindable var model: HerdrAppModel
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var sessionAction: AgentSessionAction?
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        let groups = groups
        let sessionCount = groups.reduce(0) { $0 + $1.sessionCount }

        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    AgentsHeader(model: model)

                    WorkspaceSearchField(
                        text: $query,
                        placeholder: "Search agents",
                        clearAccessibilityLabel: "Clear agent search",
                        monospaced: false
                    )

                    AgentsListSummary(
                        sessionCount: sessionCount,
                        workspaceCount: groups.count,
                        connectionState: model.connectionState
                    )

                    if groups.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No Pi sessions" : "No matching agents",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(query.isEmpty
                                ? "Open the navigator to start a Pi chat in a workspace."
                                : "Search by agent, machine, workspace, tab, or status.")
                        )
                    } else {
                        ForEach(groups) { group in
                            AgentWorkspaceSection(
                                model: model,
                                group: group,
                                selectWorkspace: selectWorkspace,
                                selectPane: selectPane,
                                confirmAction: { sessionAction = $0 }
                            )
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 8)
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
        .modifier(AgentSessionActionPresentation(model: model, action: $sessionAction))
    }

    private var groups: [AgentWorkspaceGroup] {
        AgentWorkspaceGroup.recent(workspaces: model.workspaces, machines: model.machines, query: query)
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }
}
