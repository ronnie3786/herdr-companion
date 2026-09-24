import SwiftUI

struct DashboardChatsSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    private var recentChats: [HerdrPane] {
        let machine = shell.dashboard.recentMachineID
        let workspaces = machine.isEmpty ? model.workspaces : model.workspaces.filter { $0.machineID == machine }
        return SidebarTree.recentChats(workspaces: workspaces, query: shell.dashboard.search)
    }
    private var visible: [HerdrPane] {
        recentChats.filter { !shell.dashboard.focusMode || $0.agentStatus == .blocked }
    }
    var body: some View {
        @Bindable var dashboard = shell.dashboard
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Button { shell.show(.session, model: model) } label: {
                    HStack(spacing: 5) {
                        Text("Recent chats").herdrFont(.headline)
                        Image(systemName: "chevron.right").herdrFont(.caption2)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("dashboard-recent-chats")
                Text("\(recentChats.count) most recent").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                Spacer(minLength: 8)
                Menu {
                    Picker("Recent chats machine", selection: $dashboard.recentMachineID) {
                        Text("All machines").tag("")
                        ForEach(model.machines) { machine in Text(machine.name).tag(machine.id) }
                    }
                } label: {
                    Text(model.machines.first { $0.id == dashboard.recentMachineID }?.name ?? "All machines")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                }.fixedSize().accessibilityIdentifier("dashboard-chat-machine")
            }
            if visible.isEmpty {
                Label(dashboard.focusMode ? "No recent chats are waiting for you." : dashboard.search.isEmpty ? "No recent chats" : "No chats match your search.", systemImage: "bubble.left.and.bubble.right")
                    .herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).padding(.vertical, 14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { pane in
                        DashboardChatRow(pane: pane, workspaceName: model.workspace(containing: pane)?.label ?? "Workspace",
                                         machineName: model.machines.first { $0.id == pane.machineID }?.name ?? "Machine") {
                            shell.openPane(id: pane.id, model: model)
                        }
                    }
                }
            }
        }
        .onChange(of: model.machines.map(\.id), initial: true) { _, ids in
            if !ids.isEmpty, !dashboard.recentMachineID.isEmpty, !ids.contains(dashboard.recentMachineID) {
                dashboard.recentMachineID = ""
            }
        }
    }
}
