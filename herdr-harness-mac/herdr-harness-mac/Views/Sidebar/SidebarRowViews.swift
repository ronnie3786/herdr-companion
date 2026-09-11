import SwiftUI

/// Persistent navigation uses quiet status marks, reserving color for work
/// in progress and sessions needing attention. Resting status words stay in
/// tooltips and accessibility labels, so titles have room to breathe.
enum SidebarTone {
    /// The single hue for calm status-derived elements in these rows.
    static let status = HerdrTheme.mist

    static func statusColor(for status: AgentStatus) -> Color {
        if status.needsAttention || status == .working { return status.color }
        return Self.status
    }
}

/// Fixed-size status marks keep the title column aligned independently of
/// the font's terminal glyph metrics. Shape still distinguishes resting work.
private struct SidebarStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(status == .idle ? .clear : SidebarTone.statusColor(for: status))
            .overlay {
                Circle().strokeBorder(SidebarTone.statusColor(for: status), lineWidth: 1)
            }
            .frame(width: status == .unknown ? 3 : 6, height: status == .unknown ? 3 : 6)
            .frame(width: 6, height: 6)
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
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .herdrFont(
                        size: 8,
                        weight: .semibold,
                        relativeTo: .caption2
                    )
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                Image(systemName: "folder")
                    .herdrFont(size: SidebarMetrics.hierarchyIconSize, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)

                Text(workspace.label)
                    .herdrFont(
                        size: SidebarMetrics.projectLabelSize,
                        weight: .semibold,
                        relativeTo: .subheadline
                    )
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.alert)
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                } else if !isExpanded, workingCount > 0 {
                    Text("\(workingCount) working")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.working)
                        .fixedSize()
                } else {
                    Text("\(workspace.paneCount)")
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .fixedSize()
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

    /// The tooltip retains the full status without repeating it beside every title.
    private func tooltip(workingCount: Int) -> String {
        let location = workspace.displayPath.isEmpty ? workspace.label : workspace.displayPath
        guard workingCount > 0 else { return "\(location) — \(workspace.agentStatus.title)" }
        return "\(location) — \(workspace.agentStatus.title) — \(workingCount) working"
    }

    private func accessibilityValue(workingCount: Int) -> String {
        let expansion = (isExpanded ? "expanded" : "collapsed") + (workspace.focused ? ", active workspace" : "")
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
    var createWorkspace: (() -> Void)?
    var canCreateWorkspace = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .herdrFont(size: 8, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(HerdrTheme.mist)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.snappy, value: isExpanded)

                    Image(systemName: "desktopcomputer")
                        .herdrFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(HerdrTheme.muted)

                    Text(machine.name)
                        .herdrFont(size: SidebarMetrics.projectLabelSize, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)

                    Spacer()

                    if state == .live || state == .demo {
                        Text("\(paneCount)")
                            .herdrFont(.caption2, monospacedDigit: true)
                            .foregroundStyle(HerdrTheme.muted)
                            .fixedSize()
                    } else {
                        Text(state.title)
                            .herdrFont(.caption2)
                            .foregroundStyle(state.color)
                            .fixedSize()
                    }
                }
                .frame(minHeight: SidebarMetrics.projectRowHeight)
                .contentShape(Rectangle())
            }
            .help("\(machine.name) — \(machine.urlString) — \(state.title)")
            .accessibilityIdentifier("sidebar-machine-\(machine.id)")
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(isExpanded ? "expanded" : "collapsed"), \(state.title), \(paneCount) panes")
            .accessibilityHint("Collapses or expands this machine's chats")

            if let createWorkspace {
                Button("New workspace on \(machine.name)", systemImage: "folder.badge.plus", action: createWorkspace)
                    .labelStyle(.iconOnly)
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
                    .frame(width: 28, height: SidebarMetrics.projectRowHeight)
                    .contentShape(.rect)
                    .disabled(!canCreateWorkspace)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .help("New workspace on \(machine.name)")
                    .accessibilityIdentifier("sidebar-machine-new-workspace-\(machine.id)")
            }
        }
        .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
        .padding(.trailing, SidebarMetrics.rowTrailingPadding)
        .background(isHovering ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 6))
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SidebarSectionRow: View {
    let tab: HerdrTab
    var tabColor: ChatTabColor?
    let isExpanded: Bool
    var attentionStatus: AgentStatus?
    var workingCount = 0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .herdrFont(size: 8, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(folderColor)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                if let tabColor {
                    Image(systemName: tabColor.symbol)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityLabel(tabColor.defaultLabel)
                }
                Text(tab.label)
                    .herdrFont(
                        size: SidebarMetrics.tabLabelSize,
                        weight: .medium,
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
            .background(tabColor?.rowBackground(hovering: isHovering) ?? (isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear), in: .rect(cornerRadius: 6))
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
    struct RecentContext {
        let machine: String
        let workspace: String
        let tab: String

        var accessibilityLabel: String {
            "Machine: \(machine), workspace: \(workspace), tab: \(tab)"
        }
    }

    let pane: HerdrPane
    var recentContext: RecentContext?
    var tabColor: ChatTabColor?
    var colorLabel: String?
    let isSelected: Bool
    var isStarred: Bool = false
    var isUnread: Bool = false
    var isManuallyUnread: Bool = false
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if differentiateWithoutColor, let tabColor {
                    Image(systemName: tabColor.symbol)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityHidden(true)
                }
                Group {
                    if let recentContext {
                        recentContent(recentContext)
                    } else {
                        compactContent
                    }
                }
            }
            .padding(.leading, recentContext == nil ? leadingPadding : SidebarMetrics.containerLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .padding(.vertical, recentContext == nil ? (hierarchy?.workspaceLabel != nil || parentContext != nil ? 5 : 0) : 12)
            .frame(minHeight: SidebarMetrics.chatRowHeight)
            .contentShape(Rectangle())
            .background(rowBackground, in: .rect(cornerRadius: 6))
            .overlay {
                if isSelected, let tabColor {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(tabColor.swatch.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityIdentifier("sidebar-pane-\(pane.id)")
        .accessibilityElement(children: toggleStar == nil ? .combine : .contain)
        .accessibilityLabel(accessibilityLabel)
        .overlay(alignment: .leading) { disclosureControl }
    }

    private var compactContent: some View {
        HStack(spacing: 7) {
            if isManuallyUnread {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AgentStatus.done.color)
                    .accessibilityLabel("Done, waiting for you")
            } else {
                SidebarStatusDot(status: pane.agentStatus)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(pane.displayTitle)
                    .herdrFont(size: SidebarMetrics.chatLabelSize, relativeTo: .subheadline)
                    .foregroundStyle(isSelected ? HerdrTheme.text : HerdrTheme.mist)
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

            if isManuallyUnread {
                Text("Done").herdrFont(.caption2).foregroundStyle(AgentStatus.done.color)
            } else if describesLastActivity || pane.agentStatus.needsAttention || pane.agentStatus == .working {
                SidebarStatusAgeLabel(
                    status: pane.agentStatus,
                    since: since,
                    describesLastActivity: describesLastActivity
                )
                .herdrFont(.caption2, monospacedDigit: true)
                .foregroundStyle(SidebarTone.statusColor(for: pane.agentStatus))
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var disclosureControl: some View {
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

    private func recentContent(_ context: RecentContext) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 7) {
                Text(pane.displayTitle)
                    .herdrFont(size: SidebarMetrics.chatLabelSize, relativeTo: .subheadline)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isUnread {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(HerdrTheme.accent)
                        .accessibilityLabel("Unread")
                        .padding(.top, 6)
                }
                starControl
            }
            HStack(spacing: 4) {
                Text("\(context.machine) · \(Text(context.workspace).bold())")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(context.accessibilityLabel)
                Spacer(minLength: 4)
                Label(isManuallyUnread ? "Done" : pane.agentStatus.compactTitle,
                      systemImage: isManuallyUnread ? "checkmark.circle.fill" : pane.agentStatus.symbol)
                    .foregroundStyle(isManuallyUnread ? AgentStatus.done.color : SidebarTone.statusColor(for: pane.agentStatus))
                    .fixedSize()
            }
            .herdrFont(size: 10, relativeTo: .caption2)
            .foregroundStyle(HerdrTheme.muted)
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
                    .frame(width: SidebarMetrics.starSlotWidth, height: recentContext == nil ? SidebarMetrics.chatRowHeight : 18)
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
        if let recentContext { identity += ", \(recentContext.accessibilityLabel)" }
        if let tabColor { identity += ", color group: \(colorLabel ?? tabColor.defaultLabel) (\(tabColor.defaultLabel))" }
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
        if let tabColor { return tabColor.rowBackground(selected: isSelected, hovering: isHovering) }
        if isSelected { return HerdrTheme.selection }
        return isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear
    }
}
