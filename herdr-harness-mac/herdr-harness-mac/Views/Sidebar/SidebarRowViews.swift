import SwiftUI

/// Mac-only divergence from iOS: the navigator reserves status hues for
/// sessions that need attention.
///
/// On the phone the sidebar was a drawer you glanced at; on the Mac it is on
/// screen for the whole session, and five status hues repeated down every row
/// turned the column into a rainbow that fought the detail pane for attention.
/// Calm states spend exactly one tone on status-derived dots and words, while
/// blocked and completed sessions light up in their real status color. That
/// keeps the column quiet while still making the items that need attention
/// easy to scan without opening the Attention deck. Differentiation for calm
/// states comes from the terminal glyph (`●` / `○` / `·`) and status word.
///
/// `working` now keeps its own hue and a collapsed workspace row carries a
/// low-opacity amber halo, because the workspace row is the only row that
/// cannot spell its status out in words and is the row most often collapsed
/// over its working children. `SidebarTone.statusColor` — not
/// `AgentStatus.needsAttention` — is the seam that was widened.
///
/// `mist` is the shared secondary-information tone. Accent stays reserved for
/// interactive controls and selection. Resting status words are omitted from
/// normal rows; the dot, tooltip, and accessibility label retain that context.
///
/// Deliberately scoped to the sidebar: this selective override belongs here,
/// not on the shared `AgentStatus` type.
enum SidebarTone {
    /// The single hue for calm status-derived elements in these rows.
    static let status = HerdrTheme.mist

    static let badgeFill = HerdrTheme.alert
    static let badgeLabel = HerdrTheme.ink

    static func statusColor(for status: AgentStatus) -> Color {
        if status.needsAttention || status == .working { return status.color }
        return Self.status
    }
}

/// Sidebar-local twin of `HerdrStatusDot`: same glyph and accessibility label,
/// calm states use one tone while attention states use `status.color`.
private struct SidebarStatusDot: View {
    let status: AgentStatus
    /// Amber breath for rows whose descendants are working. The dot itself keeps
    /// `SidebarTone`'s hue — the glow adds reach without spending a second color.
    var isWorking = false

    var body: some View {
        Text(status.terminalGlyph)
            .herdrFont(.body, monospaced: true, weight: .semibold)
            .foregroundStyle(SidebarTone.statusColor(for: status))
            .herdrPulseGlow(
                HerdrTheme.working,
                isActive: isWorking,
                diameter: SidebarMetrics.statusGlowDiameter
            )
            .accessibilityLabel(status.title)
    }
}

struct SidebarProjectRow: View {
    let workspace: HerdrWorkspace
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let workingCount = workspace.workingCount
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .herdrFont(
                        size: SidebarMetrics.hierarchyIconSize,
                        weight: .semibold,
                        relativeTo: .caption2
                    )
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                SidebarStatusDot(status: workspace.agentStatus, isWorking: workingCount > 0)

                Text(workspace.label)
                    .herdrFont(
                        size: SidebarMetrics.projectLabelSize,
                        weight: .semibold,
                        relativeTo: .subheadline
                    )
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                if workspace.focused {
                    Text("active")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                        .fixedSize()
                }

                Spacer()

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .herdrFont(.caption2, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(SidebarTone.badgeLabel)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SidebarTone.badgeFill, in: Capsule())
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                }
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.projectRowHeight)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip(workingCount: workingCount))
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(workingCount: workingCount))
        .accessibilityHint("Collapses or expands this workspace's chats")
    }

    /// The chat rows below spell their status out in words; a workspace row only
    /// ever carried it as a hue. With one tone the hover tooltip is where that
    /// detail goes — the mac-native place for it, and no extra chrome in the row.
    private func tooltip(workingCount: Int) -> String {
        let location = workspace.displayPath.isEmpty ? workspace.label : workspace.displayPath
        guard workingCount > 0 else { return "\(location) — \(workspace.agentStatus.title)" }
        return "\(location) — \(workspace.agentStatus.title) — \(workingCount) working"
    }

    private func accessibilityValue(workingCount: Int) -> String {
        let expansion = isExpanded ? "expanded" : "collapsed"
        guard workingCount > 0 else { return expansion }
        return "\(expansion), \(workingCount) working"
    }
}

struct SidebarMachineRow: View {
    let machine: HerdrMachine
    let state: ConnectionState
    let paneCount: Int
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                Image(systemName: "desktopcomputer")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(SidebarTone.status.opacity(statusOpacity))

                Text(machine.name)
                    .herdrFont(.subheadline, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                Text("\(paneCount) panes")
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(SidebarTone.status.opacity(statusOpacity))
                    .frame(width: 3)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(machine.name) — \(machine.urlString) — \(state.title)")
        .accessibilityIdentifier("sidebar-machine-\(machine.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this machine's chats")
    }

    private var statusOpacity: Double {
        switch state {
        case .live, .demo: 1
        case .connecting: 0.7
        case .disconnected, .failed: 0.45
        }
    }
}

struct SidebarSectionRow: View {
    let tab: HerdrTab
    let isExpanded: Bool
    var attentionStatus: AgentStatus?
    var workingCount = 0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: attentionStatus != nil ? "folder.fill" : (isExpanded ? "folder" : "folder.fill"))
                    .herdrFont(
                        size: SidebarMetrics.hierarchyIconSize,
                        relativeTo: .caption2
                    )
                    .foregroundStyle(folderColor)

                Text(tab.label)
                    .herdrFont(
                        size: SidebarMetrics.tabLabelSize,
                        weight: .semibold,
                        relativeTo: .caption
                    )
                    .foregroundStyle(attentionStatus != nil ? HerdrTheme.text : HerdrTheme.mist)
                    .lineLimit(1)

                Spacer()

                Text("\(tab.paneCount)")
                    .herdrFont(.caption2, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.leading, SidebarMetrics.tabRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.tabRowHeight)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this tab's chats")
    }

    private var folderColor: Color {
        if let attentionStatus { return attentionStatus.color }
        return workingCount > 0 ? HerdrTheme.working : HerdrTheme.mist
    }

    private var accessibilityLabel: String {
        let attention = attentionStatus.map { ", \($0.title)" } ?? ""
        let working = workingCount > 0 ? ", \(workingCount) working" : ""
        return "\(tab.label), \(tab.paneCount) panes\(attention)\(working)"
    }
}

struct SidebarChatRow: View {
    let pane: HerdrPane
    let isSelected: Bool
    var isStarred: Bool = false
    var isUnread: Bool = false
    var hierarchy: PiSessionTree.Row?
    var parentContext: String?
    /// The status age everywhere but Recents, which passes its own ranking key.
    var since: Date?
    var describesLastActivity = false
    let action: () -> Void
    /// Quick-star. Nil leaves the row read-only, which is what the render
    /// tests and any non-interactive host want.
    var toggleStar: (() -> Void)?
    var toggleChildren: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SidebarStatusDot(status: pane.agentStatus)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.displayTitle)
                        .herdrFont(size: SidebarMetrics.chatLabelSize, relativeTo: .subheadline)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    if let workspaceLabel = hierarchy?.workspaceLabel {
                        Label(workspaceLabel, systemImage: "folder")
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(1)
                            .help("Workspace: \(workspaceLabel)\n\(pane.displayPath)")
                    }
                    if let parentContext {
                        Text(parentContext)
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isUnread {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(HerdrTheme.accent)
                        .accessibilityLabel("Unread")
                }
                if let hierarchy, hierarchy.childCount > 0 {
                    Text("\(hierarchy.childCount)")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .help("\(hierarchy.childCount) child sessions")
                        .fixedSize()
                }

                starControl

                if describesLastActivity || pane.agentStatus.needsAttention || pane.agentStatus == .working {
                    SidebarStatusAgeLabel(
                        status: pane.agentStatus,
                        since: since,
                        describesLastActivity: describesLastActivity
                    )
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(SidebarTone.statusColor(for: pane.agentStatus))
                    .fixedSize()
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .padding(.vertical, hierarchy?.workspaceLabel != nil || parentContext != nil ? 5 : 0)
            .frame(minHeight: SidebarMetrics.chatRowHeight)
            .contentShape(Rectangle())
            .background(rowBackground, in: .rect(cornerRadius: 6))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? HerdrTheme.accent : .clear)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityIdentifier("sidebar-pane-\(pane.id)")
        // `.combine` would fold the star button into the row and lose its own
        // action; `.contain` keeps it separately reachable.
        .accessibilityElement(children: toggleStar == nil ? .combine : .contain)
        .accessibilityLabel(accessibilityLabel)
        .overlay(alignment: .leading) {
            if let toggleChildren, let hierarchy {
                Button(
                    hierarchy.isExpanded ? "Collapse child sessions" : "Expand child sessions",
                    systemImage: hierarchy.isExpanded ? "chevron.down" : "chevron.right",
                    action: toggleChildren
                )
                .labelStyle(.iconOnly)
                .herdrFont(.caption2, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
                .buttonStyle(.plain)
                .frame(width: 20, height: SidebarMetrics.chatRowHeight)
                .contentShape(Rectangle())
                .padding(.leading, SidebarMetrics.chatRowLeadingPadding + hierarchyIndent)
                .accessibilityIdentifier("sidebar-session-disclosure-\(pane.id)")
                .accessibilityValue(hierarchy.isExpanded ? "expanded" : "collapsed")
                .help("\(hierarchy.isExpanded ? "Collapse" : "Expand") \(hierarchy.childCount) child sessions")
            }
        }
    }

    private var hierarchyIndent: CGFloat { CGFloat(min(hierarchy?.depth ?? 0, 6)) * 16 }

    private var leadingPadding: CGFloat {
        let belongsToFamily = (hierarchy?.depth ?? 0) > 0 || (hierarchy?.childCount ?? 0) > 0
        return SidebarMetrics.chatRowLeadingPadding + hierarchyIndent + (belongsToFamily ? 20 : 0)
    }

    /// A starred row always shows its star; an unstarred one only offers the
    /// control under the pointer, so the column stays quiet until you reach for
    /// it. The slot keeps its width either way — a star that appears on hover
    /// must not shove the status age sideways.
    @ViewBuilder
    private var starControl: some View {
        if let toggleStar {
            Button(action: toggleStar) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .herdrFont(size: SidebarMetrics.hierarchyIconSize, relativeTo: .caption2)
                    .foregroundStyle(isStarred ? SidebarTone.status : HerdrTheme.muted)
                    .frame(width: SidebarMetrics.starSlotWidth, height: SidebarMetrics.chatRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isStarred || isHovering ? 1 : 0)
            .allowsHitTesting(isStarred || isHovering)
            .help(isStarred ? "Unstar this chat" : "Star this chat")
            .accessibilityLabel(isStarred ? "Unstar \(pane.displayTitle)" : "Star \(pane.displayTitle)")
            .accessibilityIdentifier("sidebar-pane-star-\(pane.id)")
        } else if isStarred {
            Image(systemName: "star.fill")
                .herdrFont(size: SidebarMetrics.hierarchyIconSize, relativeTo: .caption2)
                .foregroundStyle(SidebarTone.status)
                .frame(width: SidebarMetrics.starSlotWidth)
        } else {
            Color.clear.frame(width: SidebarMetrics.starSlotWidth)
        }
    }

    private var accessibilityLabel: String {
        var identity = "\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)"
        if let hierarchy {
            if hierarchy.depth > 0 { identity += ", child session, level \(hierarchy.depth)" }
            if let workspace = hierarchy.workspaceLabel { identity += ", workspace \(workspace)" }
            if hierarchy.childCount > 0 { identity += ", \(hierarchy.childCount) child sessions" }
        }
        if let parentContext { identity += ", \(parentContext)" }
        if isUnread { identity += ", unread" }
        guard let since else { return identity }
        let age = HerdrTimestamp.spokenAge(since: since)
        return describesLastActivity ? "\(identity), last active \(age)" : "\(identity), \(age)"
    }

    private var rowBackground: Color {
        if isSelected { return HerdrTheme.selection }
        return isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear
    }
}
