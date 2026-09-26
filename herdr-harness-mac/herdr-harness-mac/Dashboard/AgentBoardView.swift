import SwiftUI

struct AgentBoardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Environment(\.herdrHostsTitleBar) private var hostsTitleBar

    /// Columns fill the window when they fit; otherwise whole columns show with
    /// the next one peeking in, so the board always reads as scrollable.
    static func columnWidth(for width: CGFloat, count: Int) -> CGFloat {
        let slots = width < 800 ? 1 : width < 1180 ? 2 : width < 2200 ? 3 : 4
        let usable = width - 32
        if count <= slots {
            let n = CGFloat(max(count, 1))
            return min(max((usable - (n - 1) * 14) / n, 340), 720)
        }
        return min(max((usable - CGFloat(slots) * 14 - 56) / CGFloat(slots), 340), 640)
    }

    var body: some View {
        let entries = shell.dashboard.entries(shell: shell, isDemo: model.isDemoMode)
        let board = shell.agentBoard
        let visible = board.entries(entries, focusMode: false)
        VStack(spacing: 0) {
            if !hostsTitleBar {
                AgentBoardHeaderBar(model: model, shell: shell, entries: entries)
                    .herdrBar()
            }
            if visible.isEmpty {
                emptyState(hasEntries: !entries.isEmpty)
            } else {
                GeometryReader { geometry in
                    let width = Self.columnWidth(for: geometry.size.width, count: visible.count)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(visible) { entry in
                                AgentBoardColumnView(
                                    model: model,
                                    board: board,
                                    state: board.column(for: entry),
                                    entry: entry,
                                    demoSnapshot: model.isDemoMode ? shell.firstMate.snapshots[entry.feature.id] : nil,
                                    openLiveSession: { openLiveSession($0, machineID: entry.machineID) },
                                    openFullView: {
                                        shell.showFirstMate(machineID: entry.machineID, featureID: entry.feature.id,
                                                            inspector: .overview, model: model)
                                    }
                                )
                                .frame(width: width, height: max(320, geometry.size.height - 24))
                                .id(entry.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 12)
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.automatic)
                    .accessibilityIdentifier("agent-board-columns")
                }
            }
        }
        .herdrTitleBar {
            if hostsTitleBar { AgentBoardHeaderBar.Leading(shell: shell, entries: entries) }
        } trailing: {
            if hostsTitleBar { AgentBoardHeaderBar.Trailing(model: model, shell: shell) }
        }
        .herdrPaneBackground()
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.accent)
        .onChange(of: entries.map(\.id)) { _, ids in board.prune(keeping: Set(ids)) }
        // The next visit starts in priority order; while here, polls never
        // shuffle the columns under the pointer.
        .onDisappear { board.resetOrder() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-board")
    }

    @ViewBuilder
    private func emptyState(hasEntries: Bool) -> some View {
        VStack(spacing: 12) {
            if !model.isDemoMode, !shell.firstMateFleet.hosts.isEmpty, !shell.firstMateFleet.hasLoadedAnyHost {
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in AgentBoardColumnSkeleton() }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading First Mates")
            } else if hasEntries {
                Text(shell.agentBoard.filter == .needsYou ? "No First Mates need you right now." : "No First Mates are working right now.")
                    .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(HerdrTheme.secondaryText)
                Button("Show all") { shell.agentBoard.filter = .all }
                    .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
            } else {
                Text(model.isDemoMode || !model.machines.isEmpty ? "No First Mates yet." : "Connect a companion in Settings → Machines.")
                    .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(HerdrTheme.secondaryText)
                DashboardCreateFeatureMenu(model: model, shell: shell) {
                    Label("New feature", systemImage: "plus")
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium).foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

/// "Agents", the filter tabs and New feature. In the main window they sit in
/// the title bar; standalone hosts draw them as a bar.
private struct AgentBoardHeaderBar: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let entries: [DashboardFeatureEntry]

    var body: some View {
        HStack(spacing: 0) {
            Leading(shell: shell, entries: entries)
            Spacer(minLength: 12)
            Trailing(model: model, shell: shell)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }

    struct Leading: View {
        @Bindable var shell: HerdrShellState
        let entries: [DashboardFeatureEntry]

        var body: some View {
            @Bindable var board = shell.agentBoard
            HStack(spacing: 8) {
                Text("Agents")
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                DashboardSegmented(
                    selection: $board.filter,
                    segments: AgentBoardFilter.allCases.map { filter in
                        .init(value: filter, title: filter.rawValue, count: entries.filter { filter.includes($0) }.count)
                    },
                    accessibilityLabel: "First Mate filter"
                )
                .accessibilityIdentifier("agent-board-filter")
            }
        }
    }

    /// New feature (`.btn-out`).
    struct Trailing: View {
        let model: HerdrAppModel
        let shell: HerdrShellState
        @State private var isHovered = false

        var body: some View {
            DashboardCreateFeatureMenu(model: model, shell: shell) {
                Label("New feature", systemImage: "plus")
                    .labelStyle(DashboardInlineLabelStyle(spacing: 6))
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(isHovered ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: HerdrTheme.ControlHeight.large)
                    .background(isHovered ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                            .strokeBorder(isHovered ? HerdrTheme.focusOutline : HerdrTheme.outline)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityIdentifier("agent-board-new-feature")
        }
    }
}

private struct AgentBoardColumnSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSkeletonBar(width: 90, height: 14)
            DashboardSkeletonBar(width: 220, height: 14)
            RoundedRectangle(cornerRadius: HerdrTheme.nowRadius).fill(HerdrTheme.chipFill).frame(height: 52)
            DashboardSkeletonBar(width: 260)
            DashboardSkeletonBar(width: 200)
            DashboardSkeletonBar(width: 240)
            Spacer()
        }
        .padding(12)
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.cardRadius).strokeBorder(HerdrTheme.outline) }
    }
}
