import SwiftUI

struct AgentBoardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let entries: [DashboardFeatureEntry]

    var body: some View {
        @Bindable var board = shell.agentBoard
        @Bindable var dashboard = shell.dashboard
        let visibleEntries = board.entries(entries, focusMode: dashboard.focusMode)
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    title
                    filters(board: board)
                    Spacer(minLength: 8)
                    DashboardFocusToggle(isOn: $dashboard.focusMode)
                    createMenu
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        title
                        Spacer()
                        DashboardFocusToggle(isOn: $dashboard.focusMode)
                        createMenu
                    }
                    filters(board: board)
                }
            }
            .padding(24)
            Divider().overlay(HerdrTheme.separator)
            if visibleEntries.isEmpty {
                emptyState
            } else {
                if !failedHosts.isEmpty { hostNotices }
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(visibleEntries) { entry in
                                AgentBoardColumnView(
                                    model: model,
                                    state: board.column(for: entry),
                                    entry: entry,
                                    demoSnapshot: model.isDemoMode ? shell.firstMate.snapshots[entry.feature.id] : nil,
                                    openLiveSession: { openLiveSession($0, machineID: entry.machineID) },
                                    openFullView: {
                                        shell.showFirstMate(machineID: entry.machineID, featureID: entry.feature.id,
                                                            inspector: .overview, model: model)
                                    }
                                )
                                .frame(width: 380, height: max(1, geometry.size.height - 48))
                                .id(entry.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(24)
                    }
                    .scrollIndicators(.visible)
                    .accessibilityIdentifier("agent-board-columns")
                }
            }
        }
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-board")
    }

    private var title: some View {
        Text("First Mates")
            .herdrFont(.title2, weight: .semibold)
            .accessibilityAddTraits(.isHeader)
    }

    private func filters(board: AgentBoardState) -> some View {
        @Bindable var board = board
        return Picker("First Mate filter", selection: $board.filter) {
            ForEach(AgentBoardFilter.allCases) { filter in
                Text("\(filter.rawValue) \(entries.filter { filter.includes($0) }.count)").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 310)
        .accessibilityIdentifier("agent-board-filter")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.isDemoMode, !shell.firstMateFleet.hosts.isEmpty, !shell.firstMateFleet.hasLoadedAnyHost {
            ProgressView("Loading First Mates…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isDemoMode, entries.isEmpty, !failedHosts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("First Mates are unavailable")
                        .herdrFont(.title2, weight: .semibold)
                    ForEach(failedHosts) { host in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(host.machineName, systemImage: host.unsupported ? "arrow.down.circle" : "wifi.slash")
                                .herdrFont(.headline)
                            Text(host.unsupported ? "Update this companion to use First Mate." : host.error ?? "This companion is unavailable.")
                                .herdrFont(.body).foregroundStyle(HerdrTheme.muted)
                            if let date = host.lastUpdated {
                                Text("Last seen \(date, style: .relative) ago")
                                    .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                            }
                        }
                    }
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await shell.firstMateFleet.refresh() }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "sailboat")
            } description: {
                Text(emptyDescription)
            } actions: {
                if entries.isEmpty { createMenu }
                else {
                    Button("Show all First Mates") {
                        shell.agentBoard.filter = .all
                        shell.dashboard.focusMode = false
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hostNotices: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(failedHosts) { host in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(host.machineName, systemImage: host.unsupported ? "arrow.down.circle" : "wifi.slash")
                            .herdrFont(.caption, weight: .semibold)
                        Text(host.unsupported ? "Update this companion to use First Mate." : "Companion unavailable. Showing any saved work.")
                            .herdrFont(.caption)
                        if let date = host.lastUpdated {
                            HStack(spacing: 4) {
                                Text("Last seen")
                                DashboardAgeText(date: date)
                            }.herdrFont(.caption2)
                        }
                    }
                    .foregroundStyle(HerdrTheme.warning)
                    .padding(12)
                    .background(HerdrTheme.warning.opacity(0.06), in: .rect(cornerRadius: 8))
                    .help(host.error ?? "This companion needs an update.")
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var failedHosts: [FirstMateFleetHost] {
        shell.firstMateFleet.hosts.filter { $0.error != nil || $0.unsupported }
    }
    private var emptyTitle: String {
        if !entries.isEmpty { return "No First Mates match this filter." }
        return !model.isDemoMode && model.machines.isEmpty ? "Connect a companion" : "A First Mate for every feature"
    }
    private var emptyDescription: String {
        if !entries.isEmpty { return "Change the filter or turn off Focus mode to see more features." }
        return !model.isDemoMode && model.machines.isEmpty
            ? "Add a machine in Settings → Machines to start a First Mate feature."
            : "Start with a ticket or an idea to bring your crew together here."
    }

    private var createMenu: some View {
        Group {
            if model.isDemoMode {
                Button("New feature", systemImage: "plus") { createFeature(machineID: "demo") }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(model.machines) { machine in
                        Button(machine.name) { createFeature(machineID: machine.id) }
                            .disabled(!model.canControl(machineID: machine.id))
                    }
                    if model.machines.isEmpty { Text("Connect a machine in Settings") }
                } label: {
                    Label("New feature", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .disabled(model.machines.isEmpty)
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HerdrTheme.controlAccent, in: .rect(cornerRadius: 7))
        .foregroundStyle(.white)
        .accessibilityIdentifier("agent-board-new-feature")
    }

    private func openLiveSession(_ nativeSessionID: String, machineID: String) -> Bool {
        guard model.canControl(machineID: machineID),
              let pane = AgentBoardSessionRoute.livePane(
                nativeSessionID: nativeSessionID, machineID: machineID,
                panes: model.workspaces.flatMap(\.panes)
              ) else { return false }
        shell.openPane(rawPaneID: pane.paneID, machineID: machineID, model: model)
        return true
    }

    private func createFeature(machineID: String) {
        shell.createFirstMateFeature(on: machineID)
        shell.show(.firstMate, model: model)
    }
}
