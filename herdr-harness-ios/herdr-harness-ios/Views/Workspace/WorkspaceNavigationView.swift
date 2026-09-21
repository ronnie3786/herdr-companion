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
                selectPane: { pane in
                    model.openPane(id: pane.id)
                },
                openHudChats: {
                    model.workspacePath.append(.hudChats)
                }
            )
            .navigationDestination(for: WorkspaceRoute.self) { route in
                switch route {
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
                selectPane: { pane in
                    showsHudChats = false
                    model.openPane(id: pane.id)
                },
                openHudChats: {
                    showsHudChats = true
                }
            )
            .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 460)
        } detail: {
            if showsHudChats {
                HudChatsView(model: model) { paneID in
                    showsHudChats = false
                    model.openPane(id: paneID)
                }
            } else if let pane = model.pane(id: model.selectedPaneID) {
                PaneSessionView(model: model, pane: pane, hidesAppTabBar: true)
                    .id(pane.id)
            } else {
                ContentUnavailableView(
                    "Choose an agent",
                    systemImage: "terminal",
                    description: Text("Open a terminal or agent session.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
