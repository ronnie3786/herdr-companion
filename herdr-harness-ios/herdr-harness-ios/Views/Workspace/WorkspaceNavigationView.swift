import SwiftUI

struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsHudChats = false

    var body: some View {
        if horizontalSizeClass == .regular {
            regularNavigation
        } else {
            compactNavigation
        }
    }

    private var compactNavigation: some View {
        NavigationStack(path: $model.workspacePath) {
            AgentsListView(
                model: model,
                selectWorkspace: { workspace in
                    model.selectedWorkspaceID = workspace.id
                    model.workspacePath.append(.workspace(workspace.id))
                },
                selectPane: { pane in
                    model.openPane(id: pane.id)
                },
                openHudChats: {
                    model.workspacePath.append(.hudChats)
                }
            )
            .navigationDestination(for: WorkspaceRoute.self) { route in
                switch route {
                case let .workspace(id):
                    if let workspace = model.workspace(id: id) {
                        WorkspacePaneListView(model: model, workspace: workspace) { pane in
                            model.openPane(id: pane.id)
                        }
                    }
                case let .pane(id):
                    if let pane = model.pane(id: id) {
                        PaneSessionView(model: model, pane: pane, hidesAppTabBar: true)
                            .id(pane.id)
                    }
                case .hudChats:
                    HudChatsView(model: model) { paneID in
                        model.openPane(id: paneID)
                    }
                }
            }
        }
    }

    private var regularNavigation: some View {
        NavigationSplitView {
            AgentsListView(
                model: model,
                selectWorkspace: { workspace in
                    showsHudChats = false
                    model.selectedWorkspaceID = workspace.id
                    model.selectedPaneID = workspace.sortedPanes.first?.id
                },
                selectPane: { pane in
                    showsHudChats = false
                    model.openPane(id: pane.id)
                },
                openHudChats: {
                    showsHudChats = true
                }
            )
            .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 460)
        } content: {
            if showsHudChats {
                HudChatsView(model: model) { paneID in
                    showsHudChats = false
                    model.openPane(id: paneID)
                }
                .navigationSplitViewColumnWidth(min: 420, ideal: 520, max: 680)
            } else if let workspace = model.workspace(id: model.selectedWorkspaceID) {
                WorkspacePaneListView(model: model, workspace: workspace) { pane in
                    model.openPane(id: pane.id)
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 480)
            } else {
                ContentUnavailableView(
                    "Choose a workspace",
                    systemImage: "rectangle.3.group",
                    description: Text("Its tabs and panes will appear here.")
                )
            }
        } detail: {
            if showsHudChats {
                ContentUnavailableView(
                    "Saved HUD chats",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Choose or create a conversation in the middle column.")
                )
            } else if let pane = model.pane(id: model.selectedPaneID) {
                PaneSessionView(model: model, pane: pane, hidesAppTabBar: true)
                    .id(pane.id)
            } else {
                ContentUnavailableView(
                    "Choose a pane",
                    systemImage: "terminal",
                    description: Text("Open a terminal or agent session.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
