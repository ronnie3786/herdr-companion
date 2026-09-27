import SwiftUI

struct WorkspacePaneListView: View {
    /// The highlighted tab's accent wash, measured by the dusk contrast test.
    static let highlightWash = 0.06

    @Bindable var model: HerdrAppModel
    let workspace: HerdrWorkspace
    var highlightedTabID: String? = nil
    let selectPane: (HerdrPane) -> Void
    @State private var isRenamingWorkspace = false
    @State private var isConfirmingWorkspaceClose = false
    @State private var workspaceName = ""

    var body: some View {
        @Bindable var cleanupPresenter = model.cleanupPresenter
        ZStack {
            HerdrBackground(followsGlass: true)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        // Orphaned on iOS (the list screen's AttentionStrip took its
                        // slot). On the Mac this is the fleet readout above the
                        // space you are actually looking at.
                        FleetSummaryView(model: model)

                        WorkspaceHeroView(workspace: workspace)

                        ForEach(workspace.tabs) { tab in
                            tabSection(tab)
                        }

                        if workspace.tabs.isEmpty {
                            paneRows(workspace.sortedPanes)
                        }
                    }
                    .frame(maxWidth: Self.contentWidth, alignment: .leading)
                    .padding(.horizontal, HerdrTheme.pagePadding)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }
                .onAppear { scrollToHighlightedTab(proxy) }
                .onChange(of: highlightedTabID) { _, _ in scrollToHighlightedTab(proxy) }
            }
        }
        .navigationTitle(workspace.label)
        .herdrTitleBar {
            Text(workspace.label)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .lineLimit(1)
        } trailing: {
            Group {
                Menu("Workspace actions", systemImage: "ellipsis") {
                    Button("Focus on Mac", systemImage: "scope") {
                        Task { await model.focus(workspace) }
                    }
                    Button("Rename workspace", systemImage: "pencil") {
                        workspaceName = workspace.label
                        isRenamingWorkspace = true
                    }
                    Button("New tab", systemImage: "folder.badge.plus") {
                        Task { await model.createTab(in: workspace) }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    Button("Smart Cleanup This Workspace…", systemImage: "sparkles") {
                        cleanupPresenter.present(CleanupSheetTarget(
                            id: "\(workspace.machineID)|cleanup|\(workspace.workspaceID)",
                            machineID: workspace.machineID,
                            machineName: model.machines.first(where: { $0.id == workspace.machineID })?.name ?? "this machine",
                            workspaceID: workspace.workspaceID,
                            workspaceLabel: workspace.label
                        ), using: model)
                    }
                    .disabled(!model.canControl(machineID: workspace.machineID))
                    .accessibilityIdentifier("workspace-cleanup-\(workspace.workspaceID)")
                    Divider()
                    Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
                        isConfirmingWorkspaceClose = true
                    }
                }
                .herdrIconMenu()
                .help("Workspace actions")
                .disabled(!model.canControl)
            }
        }
        .alert("Rename workspace", isPresented: $isRenamingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task { await model.rename(workspace, label: workspaceName) }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .confirmationDialog(
            "Close this workspace?",
            isPresented: $isConfirmingWorkspaceClose,
            titleVisibility: .visible
        ) {
            Button("Close workspace", role: .destructive) {
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(workspace.paneCount) pane processes in this workspace will stop.")
        }
        .sheet(item: $cleanupPresenter.target) { target in
            if let controller = cleanupPresenter.controller {
                CleanupSheet(target: target, controller: controller)
            }
        }
    }

    private func scrollToHighlightedTab(_ proxy: ScrollViewProxy) {
        guard let highlightedTabID else { return }
        proxy.scrollTo(highlightedTabID, anchor: .center)
    }

    /// The overview owns the detail column of a wide window; the cards read
    /// better in a capped column than stretched across 1000pt.
    private static let contentWidth = 760.0

    private func tabSection(_ tab: HerdrTab) -> some View {
        let panes = workspace.sortedPanes.filter { $0.scopedTabID == tab.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tab.label, systemImage: "folder")
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                Spacer()
                Text("^[\(panes.count) pane](inflect: true)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            .contextMenu { ChatTabColorMenu(store: model.chatTabColors, tabID: tab.id) }
            if panes.count == 1, let pane = panes.first, pane.reservedShell {
                ReservedShellView(model: model, pane: pane, openPane: { selectPane(pane) })
                    .frame(minHeight: 260)
            } else {
                paneRows(panes)
            }
        }
        .padding(highlightedTabID == tab.id ? 12 : 0)
        .background(
            // A light wash (the accent outline carries the highlight) so status
            // badges on the cards inside keep 4.5:1 over the dusk.
            highlightedTabID == tab.id ? HerdrTheme.accent.opacity(Self.highlightWash) : .clear,
            in: .rect(cornerRadius: HerdrTheme.cardRadius)
        )
        .overlay {
            if highlightedTabID == tab.id {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1)
            }
        }
        .id(tab.id)
        .accessibilityValue(highlightedTabID == tab.id ? "Requested tab" : "")
    }

    private func paneRows(_ panes: [HerdrPane]) -> some View {
        VStack(spacing: 10) {
            ForEach(panes) { pane in
                Button {
                    selectPane(pane)
                } label: {
                    PaneCardView(
                        pane: pane,
                        isSelected: pane.id == model.selectedPaneID,
                        colorLabel: model.chatTabColors.color(for: pane.scopedTabID).map { model.chatTabColors.label(for: $0) }
                    )
                }
                .buttonStyle(.herdrPlain)
                .contextMenu { ChatTabColorMenu(store: model.chatTabColors, tabID: pane.scopedTabID) }
                .accessibilityIdentifier("pane-\(pane.id)")
            }
        }
    }

}
