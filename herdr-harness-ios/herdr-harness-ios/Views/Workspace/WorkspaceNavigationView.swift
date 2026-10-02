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
                    model.beginAppNavigation()
                    model.workspacePath.append(.hudChats)
                }
            )
            .navigationDestination(for: WorkspaceRoute.self) { route in
                switch route {
                case let .pane(id):
                    if let pane = model.pane(id: id) {
                        PaneSessionView(
                            model: model,
                            pane: pane,
                            hidesAppTabBar: true,
                            navigationContext: .pushed
                        )
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
        GeometryReader { geometry in
            HStack(spacing: 0) {
                AgentsListView(
                    model: model,
                    selectPane: { pane in
                        showsHudChats = false
                        model.openPane(id: pane.id)
                    },
                    openHudChats: {
                        model.beginAppNavigation()
                        showsHudChats = true
                    },
                    embedded: true,
                    showsHudChats: showsHudChats
                )
                .frame(width: min(320, max(280, geometry.size.width * 0.30)))
                .clipped()
                .background {
                    HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground)
                        .overlay(alignment: .trailing) { AgentsColumnDivider() }
                        .ignoresSafeArea()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agents-sidebar-column")

                ZStack {
                    if showsHudChats {
                        HudChatsView(model: model, openPane: { paneID in
                            showsHudChats = false
                            model.openPane(id: paneID)
                        }, embedded: true)
                    } else if let pane = model.pane(id: model.selectedPaneID) {
                        PaneSessionView(
                            model: model,
                            pane: pane,
                            hidesAppTabBar: false,
                            navigationContext: .root,
                            embedded: true
                        )
                        .id(pane.id)
                    } else {
                        ContentUnavailableView(
                            "Choose an agent",
                            systemImage: "terminal",
                            description: Text("Open a terminal or agent session.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agents-detail-column")
            }
        }
        .background { AgentsWorkspaceBackdrop().ignoresSafeArea() }
        .toolbarVisibility(.visible, for: .tabBar)
        .herdrFirstMateChrome()
    }
}

private struct AgentsWorkspaceBackdrop: View {
    @Environment(\.herdrGlassActive) private var glass
    var body: some View { HerdrAppBackdrop(active: glass).allowsHitTesting(false).accessibilityHidden(true) }
}

private struct AgentsColumnDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Rectangle().fill(HerdrTheme.rule(HerdrTheme.hairline, contrast: contrast)).frame(width: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
