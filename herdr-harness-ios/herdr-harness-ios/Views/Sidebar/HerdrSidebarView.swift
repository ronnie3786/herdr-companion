import SwiftUI

struct HerdrSidebarView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentingColorFilter = false
    @State private var isPresentingCreateWorkspace = false
    @State private var isPresentingMachines = false
    @State private var creatingWorkspaceMachineID: String?
    @State private var renamingWorkspace: HerdrWorkspace?
    @State private var workspaceName = ""
    @State private var renamingPane: HerdrPane?
    @State private var paneName = ""
    @State private var renamingTab: HerdrTab?
    @State private var tabName = ""
    @State private var closingWorkspace: HerdrWorkspace?
    @State private var closingPane: HerdrPane?

    var body: some View {
        let projection = sidebarProjection

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SidebarHeaderView(model: model, close: dismiss)

                if model.machines.count > 1 {
                    machinePicker
                }

                WorkspaceSearchField(text: $model.sidebarQuery, placeholder: "Filter chats")

                ChatTabColorFilterButton(
                    store: model.chatTabColors,
                    selectedColor: model.sidebarColorFilter,
                    action: { isPresentingColorFilter = true }
                )

                SidebarCreationControls(
                    model: model,
                    showsMachineChrome: showsMachineChrome,
                    scopedMachineID: scopedMachineID,
                    presentCreateWorkspace: presentCreateWorkspace,
                    dismissSidebar: dismiss
                )

                HerdrSectionLabel(
                    title: "chats",
                    detail: sidebarCountDetail(projection.visiblePaneCount),
                    monospaced: false
                )
                .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                LazyVStack(alignment: .leading, spacing: 2) {
                    sidebarRows(projection)
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, SidebarMetrics.containerHorizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .sheet(isPresented: $isPresentingColorFilter) {
            ChatTabColorFilterSheet(
                store: model.chatTabColors,
                activeColors: activeColors,
                paneCounts: colorPaneCounts,
                selection: $model.sidebarColorFilter
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isPresentingCreateWorkspace) {
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(
                    label: label,
                    cwd: cwd,
                    machineID: creatingWorkspaceMachineID
                )
                if created { isPresentingCreateWorkspace = false }
                return created
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isPresentingMachines) {
            NavigationStack {
                MachinesView(model: model)
            }
        }
        .alert("Rename workspace", isPresented: isRenamingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let workspace = renamingWorkspace else { return }
                Task { await model.rename(workspace, label: workspaceName) }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .alert("Rename pane", isPresented: isRenamingPane) {
            TextField("Pane name", text: $paneName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let pane = renamingPane else { return }
                Task { await model.rename(pane, label: paneName) }
            }
            .disabled(paneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This label is shared with Herdr on your Mac.")
        }
        .alert("Rename tab", isPresented: isRenamingTab) {
            TextField("Tab name", text: $tabName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                guard let tab = renamingTab else { return }
                Task { await model.rename(tab, label: tabName) }
            }
            .disabled(tabName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .confirmationDialog("Close this workspace?", isPresented: isClosingWorkspace, titleVisibility: .visible) {
            Button("Close workspace", role: .destructive) {
                guard let workspace = closingWorkspace else { return }
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(closingWorkspace?.paneCount ?? 0) pane processes in this workspace will stop.")
        }
        .confirmationDialog("Close this pane?", isPresented: isClosingPane, titleVisibility: .visible) {
            Button("Close pane", role: .destructive) {
                guard let pane = closingPane else { return }
                Task { await model.close(pane) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the process running in \(closingPane?.displayTitle ?? "this pane").")
        }
    }

    private var sidebarProjection: SidebarProjection {
        SidebarProjection(
            workspaces: model.workspaces,
            machines: model.machines,
            machineStates: model.machineStates,
            machineScope: model.machineScope,
            query: model.sidebarQuery,
            recency: model.sidebarRecency,
            colorFilterTabIDs: model.sidebarColorFilter.map { model.chatTabColors.tabIDs(for: $0) },
            collapsedMachineIDs: model.collapsedSidebarMachineIDs,
            collapsedWorkspaceIDs: model.collapsedSidebarWorkspaceIDs,
            collapsedTabIDs: model.collapsedSidebarTabIDs,
            starredPaneIDs: model.starredChatIDs,
            unreadPaneIDs: model.unreadPaneIDs
        )
    }

    private var machinePicker: some View {
        Menu {
            Button("All Machines") { model.setMachineScope(.all) }
            ForEach(model.machines) { machine in
                Button {
                    model.setMachineScope(.machine(machine.id))
                } label: {
                    Label(machine.name, systemImage: "desktopcomputer")
                }
                .accessibilityValue(model.connectionState(forMachine: machine.id).title)
            }
            Divider()
            Button("Manage Machines…", systemImage: "server.rack") {
                isPresentingMachines = true
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "desktopcomputer")
                    .accessibilityHidden(true)
                Text(scopeTitle)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.bold())
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(HerdrTheme.mist)
            .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
            .frame(minHeight: SidebarMetrics.controlHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-machine-picker")
        .accessibilityLabel("Machine scope")
        .accessibilityValue(scopeTitle)
    }

    @ViewBuilder
    private func sidebarRows(_ projection: SidebarProjection) -> some View {
        if projection.isRecents {
            recentsSection(projection)
        } else {
            unreadSection(projection)
            starredSection(projection)
            groupedContent(projection)
        }
    }

    @ViewBuilder
    private func recentsSection(_ projection: SidebarProjection) -> some View {
        if projection.recentChats.isEmpty {
            filteredEmptyState(
                title: "No recent chats",
                description: "Try another machine, color, or search."
            )
        } else {
            sectionHeader("Recents", count: projection.recentChats.count, identifier: "sidebar-recents-section")
            ForEach(projection.recentChats) { pane in
                chatRow(pane, recentContext: recentContext(for: pane))
            }
        }
    }

    @ViewBuilder
    private func unreadSection(_ projection: SidebarProjection) -> some View {
        if !projection.unreadGroups.isEmpty {
            sectionHeader("Unread", count: projection.unreadGroups.reduce(0) { $0 + $1.chats.count }, identifier: "sidebar-unread-section")
            ForEach(projection.unreadGroups) { group in
                priorityGroupLabel(group.workspace)
                ForEach(group.chats) { pane in
                    chatRow(pane)
                }
            }
            Color.clear.frame(height: 6)
        }
    }

    @ViewBuilder
    private func starredSection(_ projection: SidebarProjection) -> some View {
        if !projection.starredGroups.isEmpty {
            sectionHeader("Starred", count: projection.starredGroups.reduce(0) { $0 + $1.chats.count }, identifier: "sidebar-starred-section")
            ForEach(projection.starredGroups) { group in
                priorityGroupLabel(group.workspace)
                ForEach(group.chats) { pane in
                    chatRow(pane)
                }
            }
            Color.clear.frame(height: 6)
        }
    }

    @ViewBuilder
    private func groupedContent(_ projection: SidebarProjection) -> some View {
        if projection.visiblePaneCount == 0, hasActiveListFilter {
            filteredEmptyState(
                title: "No matching chats",
                description: "Try another range, machine, color, or search."
            )
        } else if showsMachineChrome {
            ForEach(projection.machineGroups) { group in
                SidebarMachineRow(
                    machine: group.machine,
                    state: group.state,
                    paneCount: machinePaneCount(for: group.machine.id),
                    isExpanded: group.isExpanded,
                    action: { toggle(group.machine) }
                )
                if group.isExpanded {
                    if group.entries.isEmpty {
                        Text("No matching workspaces")
                            .font(.caption)
                            .foregroundStyle(HerdrTheme.muted)
                            .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
                            .frame(minHeight: SidebarMetrics.placeholderRowHeight)
                    } else {
                        entriesContent(group.entries)
                    }
                }
                machineSeparator
            }
        } else if projection.tree.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
        } else {
            entriesContent(projection.tree)
        }
    }

    @ViewBuilder
    private func entriesContent(_ entries: [SidebarTree.ProjectEntry]) -> some View {
        ForEach(entries) { entry in
            SidebarProjectRow(
                workspace: entry.workspace,
                isExpanded: entry.isExpanded,
                action: { toggle(entry.workspace) }
            )
            .contextMenu { workspaceMenu(entry.workspace) }

            if entry.isExpanded {
                ForEach(entry.sections) { section in
                    let tabColor = model.chatTabColors.color(for: section.tab.id)
                    SidebarSectionRow(
                        tab: section.tab,
                        tabColor: tabColor,
                        colorLabel: tabColor.map { model.chatTabColors.label(for: $0) },
                        isExpanded: section.isExpanded,
                        attentionStatus: tabAttentionStatus(section.tab, in: entry.workspace),
                        workingCount: tabWorkingCount(section.tab, in: entry.workspace),
                        action: { toggle(section.tab) }
                    )
                    .contextMenu { tabMenu(section.tab, in: entry.workspace) }

                    if section.isExpanded {
                        ForEach(section.chats) { pane in
                            chatRow(pane)
                        }
                    }
                }

                ForEach(entry.looseChats) { pane in
                    chatRow(pane)
                }

                if entry.sections.isEmpty && entry.looseChats.isEmpty {
                    Text("No panes yet")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
                        .frame(minHeight: SidebarMetrics.placeholderRowHeight)
                }
            }

            Color.clear.frame(height: 6)
        }
    }

    private func sectionHeader(_ title: String, count: Int, identifier: String) -> some View {
        HStack {
            Text(title)
                .bold()
            Spacer(minLength: 8)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(HerdrTheme.mist)
        .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func priorityGroupLabel(_ workspace: HerdrWorkspace) -> some View {
        Text(priorityGroupTitle(workspace))
            .font(.caption.bold())
            .foregroundStyle(HerdrTheme.muted)
            .lineLimit(2)
            .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
            .padding(.top, 4)
            .frame(minHeight: SidebarMetrics.controlHeight, alignment: .leading)
            .contextMenu { workspaceMenu(workspace) }
    }

    private func chatRow(_ pane: HerdrPane, recentContext: SidebarRecentContext? = nil) -> some View {
        let color = model.chatTabColors.color(for: pane.scopedTabID)
        return SidebarChatRow(
            pane: pane,
            recentContext: recentContext,
            tabColor: color,
            colorLabel: color.map { model.chatTabColors.label(for: $0) },
            isSelected: pane.id == model.selectedPaneID,
            isStarred: model.starredChatIDs.contains(pane.id),
            isUnread: model.unreadPaneIDs.contains(pane.id),
            since: recentContext == nil ? statusSince(for: pane) : (pane.lastActivityAt ?? pane.firstSeenAt),
            action: { open(pane) }
        )
        .contextMenu {
            if recentContext != nil, let workspace = model.workspace(containing: pane) {
                Button("Open \(workspace.label) workspace", systemImage: "folder") {
                    model.openWorkspace(id: workspace.id)
                    dismiss()
                }
                Divider()
            }

            Button(
                model.starredChatIDs.contains(pane.id) ? "Unstar chat" : "Star chat",
                systemImage: model.starredChatIDs.contains(pane.id) ? "star.slash" : "star"
            ) {
                model.toggleStarredChat(pane.id)
            }
            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Focus on Mac + Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                Task { await model.focusAndZoom(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                Task { await model.sendKeys(["ctrl+c"], to: pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            ChatTabColorMenu(store: model.chatTabColors, tabID: pane.scopedTabID)
            Button("Rename pane", systemImage: "pencil") {
                paneName = pane.displayTitle
                renamingPane = pane
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            Menu("Split pane", systemImage: "rectangle.split.2x1") {
                Button("Split right", systemImage: "rectangle.split.2x1") {
                    Task { await model.split(pane, direction: "right") }
                }
                Button("Split down", systemImage: "rectangle.split.1x2") {
                    Task { await model.split(pane, direction: "down") }
                }
            }
            .disabled(!model.canControl(machineID: pane.machineID))
            if pane.agentStatus == .unknown {
                Menu("Start agent", systemImage: "cpu") {
                    Button("Codex") { Task { await model.startAgent(in: pane, kind: "codex") } }
                    Button("Claude") { Task { await model.startAgent(in: pane, kind: "claude") } }
                    Button("OpenCode") { Task { await model.startAgent(in: pane, kind: "opencode") } }
                }
                .disabled(!model.canControl(machineID: pane.machineID))
            }
            Divider()
            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                closingPane = pane
            }
            .disabled(!model.canControl(machineID: pane.machineID))
        }
    }

    @ViewBuilder
    private func tabMenu(_ tab: HerdrTab, in workspace: HerdrWorkspace) -> some View {
        let firstPane = firstPane(in: tab, workspace: workspace)
        ChatTabColorMenu(store: model.chatTabColors, tabID: tab.id)
        Divider()
        Button("Focus on Mac", systemImage: "scope") {
            guard let firstPane else { return }
            Task { await model.focus(firstPane) }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
        Button("Rename tab", systemImage: "pencil") {
            tabName = tab.label
            renamingTab = tab
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        .accessibilityIdentifier("sidebar-tab-rename-\(tab.id)")
        Button("New Pi Chat", systemImage: "plus.bubble") {
            Task { await model.addPane(toTab: tab, in: workspace, running: "pi") }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
        Button("New Shell", systemImage: "terminal") {
            Task { await model.addPane(toTab: tab, in: workspace) }
        }
        .disabled(firstPane == nil || !model.canControl(machineID: workspace.machineID))
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: HerdrWorkspace) -> some View {
        Button("Open workspace", systemImage: "arrow.right.square") {
            model.openWorkspace(id: workspace.id)
            dismiss()
        }
        Button("Focus on Mac", systemImage: "scope") {
            Task { await model.focus(workspace) }
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Button("Rename workspace", systemImage: "pencil") {
            workspaceName = workspace.label
            renamingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Button("New tab", systemImage: "folder.badge.plus") {
            Task { await model.createTab(in: workspace) }
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
        Divider()
        Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
            closingWorkspace = workspace
        }
        .disabled(!model.canControl(machineID: workspace.machineID))
    }

    private var scopedColorWorkspaces: [HerdrWorkspace] {
        guard case let .machine(id) = model.machineScope else { return model.workspaces }
        return model.workspaces.filter { $0.machineID == id }
    }

    private var activeColors: [ChatTabColor] {
        let tabIDs = Set(scopedColorWorkspaces.flatMap { workspace in
            workspace.tabs.map(\.id) + workspace.panes.map(\.scopedTabID)
        })
        return model.chatTabColors.activeColors(tabIDs: tabIDs)
    }

    private var colorPaneCounts: [ChatTabColor: Int] {
        scopedColorWorkspaces.flatMap(\.panes).reduce(into: [:]) { counts, pane in
            guard let color = model.chatTabColors.color(for: pane.scopedTabID) else { return }
            counts[color, default: 0] += 1
        }
    }

    private var showsMachineChrome: Bool {
        if case .all = model.machineScope { return model.machines.count > 1 }
        return false
    }

    private var scopedMachineID: String? {
        if case let .machine(id) = model.machineScope { return id }
        return nil
    }

    private var scopeTitle: String {
        if case let .machine(id) = model.machineScope,
           let machine = model.machines.first(where: { $0.id == id }) {
            return machine.name
        }
        return "All Machines"
    }

    private var hasActiveListFilter: Bool {
        !model.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.sidebarColorFilter != nil
            || model.sidebarRecency != .all
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(get: { renamingWorkspace != nil }, set: { if !$0 { renamingWorkspace = nil } })
    }

    private var isRenamingPane: Binding<Bool> {
        Binding(get: { renamingPane != nil }, set: { if !$0 { renamingPane = nil } })
    }

    private var isRenamingTab: Binding<Bool> {
        Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
    }

    private var isClosingWorkspace: Binding<Bool> {
        Binding(get: { closingWorkspace != nil }, set: { if !$0 { closingWorkspace = nil } })
    }

    private var isClosingPane: Binding<Bool> {
        Binding(get: { closingPane != nil }, set: { if !$0 { closingPane = nil } })
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Herdr workspaces",
            systemImage: "rectangle.3.group",
            description: Text("Create a workspace here or on your Mac to begin.")
        )
    }

    private func filteredEmptyState(title: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(description)
        } actions: {
            if !model.sidebarQuery.isEmpty || model.sidebarColorFilter != nil {
                Button("Clear search and color") {
                    model.sidebarQuery = ""
                    model.sidebarColorFilter = nil
                }
                .frame(minHeight: SidebarMetrics.controlHeight)
            }
            if model.sidebarRecency != .all {
                Button("Show all chats") {
                    model.sidebarRecency = .all
                }
                .frame(minHeight: SidebarMetrics.controlHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private func recentContext(for pane: HerdrPane) -> SidebarRecentContext {
        let workspace = model.workspace(containing: pane)
        let tab = workspace?.tabs.first { $0.id == pane.scopedTabID }
        return SidebarRecentContext(
            machine: model.machines.first { $0.id == pane.machineID }?.name ?? "Unknown machine",
            workspace: workspace?.label ?? "Unknown workspace",
            tab: tab?.label ?? "Untitled tab"
        )
    }

    private func priorityGroupTitle(_ workspace: HerdrWorkspace) -> String {
        guard showsMachineChrome,
              let machine = model.machines.first(where: { $0.id == workspace.machineID })
        else { return workspace.label }
        return "\(machine.name) · \(workspace.label)"
    }

    private func machinePaneCount(for machineID: String) -> Int {
        model.workspaces
            .filter { $0.machineID == machineID }
            .reduce(0) { $0 + $1.paneCount }
    }

    private func tabAttentionStatus(_ tab: HerdrTab, in workspace: HerdrWorkspace) -> AgentStatus? {
        let statuses = workspace.panes
            .filter { $0.scopedTabID == tab.id }
            .map(\.agentStatus)
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.done) { return .done }
        return nil
    }

    private func tabWorkingCount(_ tab: HerdrTab, in workspace: HerdrWorkspace) -> Int {
        workspace.panes.count(where: { $0.scopedTabID == tab.id && $0.agentStatus == .working })
    }

    private func firstPane(in tab: HerdrTab, workspace: HerdrWorkspace) -> HerdrPane? {
        workspace.panes
            .filter { $0.scopedTabID == tab.id }
            .sorted { $0.paneID < $1.paneID }
            .first
    }

    private func sidebarCountDetail(_ count: Int) -> String {
        switch model.sidebarRecency {
        case .today: "\(count) today"
        case .last3Days: "\(count) in 3 days"
        case .thisWeek: "\(count) this week"
        case .all: "\(count) shown"
        case .recents: "\(count) recent"
        }
    }

    private func statusSince(for pane: HerdrPane) -> Date? {
        let newestMatchingAlert = model.alerts.lazy
            .filter {
                $0.machineID == pane.machineID
                    && $0.paneID == pane.paneID
                    && $0.status == pane.agentStatus
            }
            .compactMap(\.createdDate)
            .max()
        if pane.agentStatus == .working {
            return pane.workingSince ?? newestMatchingAlert
        }
        return newestMatchingAlert
    }

    private var machineSeparator: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.65))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func presentCreateWorkspace(for machineID: String?) {
        creatingWorkspaceMachineID = machineID
        isPresentingCreateWorkspace = true
    }

    private func toggle(_ workspace: HerdrWorkspace) {
        guard model.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(reduceMotion ? nil : .snappy) { model.toggleSidebarSection(workspace.id) }
    }

    private func toggle(_ tab: HerdrTab) {
        guard model.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(reduceMotion ? nil : .snappy) { model.toggleSidebarTabSection(tab.id) }
    }

    private func toggle(_ machine: HerdrMachine) {
        guard model.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(reduceMotion ? nil : .snappy) { model.toggleSidebarMachineSection(machine.id) }
    }

    private func open(_ pane: HerdrPane) {
        model.openPane(id: pane.id)
        dismiss()
    }

    private func dismiss() {
        withAnimation(reduceMotion ? nil : .snappy) {
            model.isSidebarPresented = false
        }
    }
}
