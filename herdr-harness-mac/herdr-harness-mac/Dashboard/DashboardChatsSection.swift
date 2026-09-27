import SwiftUI

struct DashboardChatsSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @State private var showsAll = false

    static let collapsedCount = 8

    /// The sidebar's recents, minus PR Review worker sessions (they have their
    /// own section) and plain reserved shells. Focus mode filters before the
    /// limit so a waiting chat is never cut off by busier ones.
    static func rows(workspaces: [HerdrWorkspace], machineID: String, excludedWorkspaceLabel: String,
                     query: String, focusMode: Bool) -> [HerdrPane] {
        let scoped = workspaces.filter {
            (machineID.isEmpty || $0.machineID == machineID) && $0.label != excludedWorkspaceLabel
        }
        let candidates = SidebarTree.recentChats(workspaces: scoped, query: query, limit: focusMode ? 500 : 60)
            .filter { !$0.reservedShell && (!focusMode || $0.agentStatus == .blocked) }
        return Array(candidates.prefix(SidebarRecency.recentsLimit))
    }

    var body: some View {
        @Bindable var dashboard = shell.dashboard
        let rows = Self.rows(
            workspaces: model.workspaces, machineID: dashboard.recentMachineID,
            excludedWorkspaceLabel: shell.prReview.capabilities?.workspaceLabel ?? "PR Reviews",
            query: dashboard.search, focusMode: dashboard.focusMode)
        let shown = showsAll ? rows : Array(rows.prefix(Self.collapsedCount))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DashboardSectionHeading(title: "Recent chats", identifier: "dashboard-recent-chats") {
                    shell.show(.session, model: model)
                }
                Spacer(minLength: 8)
                if model.machines.count > 1 {
                    Menu {
                        Picker("Machine", selection: $dashboard.recentMachineID) {
                            Text("All machines").tag("")
                            ForEach(model.machines) { machine in Text(machine.name).tag(machine.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(model.machines.first { $0.id == dashboard.recentMachineID }?.name ?? "All machines")
                            .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            .foregroundStyle(HerdrTheme.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .tint(HerdrTheme.accent)
                    .fixedSize()
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .accessibilityIdentifier("dashboard-chat-machine")
                }
            }
            if rows.isEmpty {
                Label(dashboard.focusMode ? "No chats are waiting for you." : dashboard.search.isEmpty ? "No recent chats." : "No chats match your search.",
                      systemImage: "bubble.left.and.bubble.right")
                    .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { pane in
                        DashboardChatRow(pane: pane,
                                         workspaceName: model.workspace(containing: pane)?.label ?? "Workspace",
                                         machineName: model.machines.first { $0.id == pane.machineID }?.name ?? "Machine") {
                            shell.openPane(id: pane.id, model: model)
                        }
                    }
                }
                .herdrHairline(.top)
                if rows.count > Self.collapsedCount {
                    Button(showsAll ? "Show fewer" : "Show \(rows.count - Self.collapsedCount) more") { showsAll.toggle() }
                        .buttonStyle(.herdrPlain)
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                        .padding(.leading, 8)
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

struct DashboardChatRow: View {
    let pane: HerdrPane
    let workspaceName: String
    let machineName: String
    let open: () -> Void
    @State private var isHovered = false
    private var needsAttention: Bool { pane.agentStatus == .blocked }

    /// Pi sessions are titled "π - <name>"; the marker adds nothing here.
    private var title: String {
        let value = pane.displayTitle
        return value.hasPrefix("π - ") ? String(value.dropFirst(4)) : value
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if needsAttention { Image(systemName: "diamond.fill").foregroundStyle(HerdrTheme.attention) }
                    else if pane.agentStatus == .working { Image(systemName: "circle.lefthalf.filled").foregroundStyle(HerdrTheme.signal) }
                    else { Color.clear }
                }
                .imageScale(.small)
                .herdrIconSlot(width: 12)
                .accessibilityHidden(true)
                Text(title)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(needsAttention ? HerdrTheme.attention : HerdrTheme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(workspaceName) · \(machineName)")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                // A hidden template keeps the age column aligned and sized to the
                // text scale, with or without a date.
                Text("000d")
                    .hidden()
                    .overlay(alignment: .trailing) {
                        if let date = pane.lastActivityAt ?? pane.firstSeenAt {
                            DashboardAgeText(date: date)
                        }
                    }
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: HerdrTheme.ControlHeight.row, alignment: .leading)
            .background(isHovered ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .herdrHairline(.bottom, color: HerdrTheme.rowDivider)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovered = $0 }
        .help(pane.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityValue(needsAttention ? "Needs input" : pane.agentStatus == .working ? "Working" : "")
        .accessibilityIdentifier("dashboard-chat-\(pane.id)")
    }
}
