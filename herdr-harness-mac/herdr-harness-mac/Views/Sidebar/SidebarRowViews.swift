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

    /// MonoCode's small status glyphs: a check for ready, a dotted ring for
    /// working, a raised hand for needs-you.
    static func statusSymbol(for status: AgentStatus) -> String? {
        switch status {
        case .blocked: "hand.raised"
        case .done: "checkmark"
        case .working: "circle.dotted"
        case .idle, .unknown: nil
        }
    }

    /// The agent glyph on a session card's first line.
    static func agentSymbol(for pane: HerdrPane) -> String {
        let name = (pane.agent ?? pane.displayAgent ?? "").lowercased()
        if pane.reservedShell || (pane.agentStatus == .unknown && name.isEmpty) { return "terminal" }
        if name.contains("claude") { return "sparkle" }
        if name.contains("codex") { return "hexagon" }
        if name == "pi" { return "p.circle" }
        return "cpu"
    }
}

/// Where a row sits inside a workspace's folder group, which MonoCode draws as
/// one 3% ink block with 6pt corners. Rows paint their own slice so the lazy
/// list stays flat.
enum SidebarFolderStrip {
    case none, top, middle, bottom, single

    fileprivate var shape: UnevenRoundedRectangle {
        let r = HerdrTheme.Radius.control
        switch self {
        case .top: return UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r)
        case .bottom: return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
        case .single: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r)
        case .none, .middle: return UnevenRoundedRectangle()
        }
    }
}

extension View {
    func sidebarFolderStrip(_ strip: SidebarFolderStrip) -> some View {
        background {
            if strip != .none {
                strip.shape.fill(HerdrTheme.cardFill)
            }
        }
    }
}

/// The status glyph and "status · age" text used on session cards.
private struct SidebarCardStatus: View {
    let status: AgentStatus
    let since: Date?
    var describesLastActivity = false
    var isManuallyUnread = false

    var body: some View {
        HStack(spacing: 5) {
            if isManuallyUnread {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityLabel("Done, waiting for you")
                Text("done")
            } else {
                if let symbol = SidebarTone.statusSymbol(for: status) {
                    Image(systemName: symbol)
                        .herdrFont(size: SidebarMetrics.metaLabelSize, weight: .semibold)
                        .accessibilityHidden(true)
                }
                SidebarStatusAgeLabel(status: status, since: since, describesLastActivity: describesLastActivity)
            }
        }
        .herdrFont(size: SidebarMetrics.metaLabelSize)
        .monospacedDigit()
        .foregroundStyle(isManuallyUnread ? AgentStatus.done.color : statusColor)
        .lineLimit(1)
        .fixedSize()
    }

    private var statusColor: Color {
        status.needsAttention || status == .working ? status.color : HerdrTheme.tertiaryText
    }
}

/// A workspace folder: the header of its folder group.
struct SidebarProjectRow: View {
    let workspace: HerdrWorkspace
    let isExpanded: Bool
    var isSelected = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let workingCount = workspace.workingCount
        Button(action: action) {
            HStack(spacing: 6) {
                // MonoCode swaps the folder for a chevron under the pointer.
                ZStack {
                    Image(systemName: "folder.fill")
                        .herdrFont(size: SidebarMetrics.workspaceIconSize, relativeTo: .caption)
                        .foregroundStyle(folderIconColor)
                        .opacity(isHovering ? 0 : 1)
                    Image(systemName: "chevron.right")
                        .herdrFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(HerdrTheme.iconTint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(isHovering ? 1 : 0)
                }
                .frame(width: 16)
                .animation(.snappy, value: isExpanded)
                .accessibilityHidden(true)

                Text(workspace.label)
                    .herdrFont(
                        size: SidebarMetrics.workspaceLabelSize,
                        weight: SidebarMetrics.workspaceLabelWeight,
                        relativeTo: .subheadline
                    )
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .herdrFont(size: SidebarMetrics.metaLabelSize)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.alert)
                        .fixedSize()
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                } else if !isExpanded, workingCount > 0 {
                    Text("\(workingCount) working")
                        .herdrFont(size: SidebarMetrics.metaLabelSize, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.working)
                        .fixedSize()
                } else {
                    Text("\(workspace.paneCount)")
                        .herdrFont(size: SidebarMetrics.metaLabelSize)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .fixedSize()
                }
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.workspaceRowHeight)
            .contentShape(Rectangle())
            .herdrRowBackground(selected: isSelected, hovered: isHovering)
        }
        .buttonStyle(.plain)
        .sidebarFolderStrip(isExpanded ? .top : .single)
        .onHover { isHovering = $0 }
        .help(tooltip(workingCount: workingCount))
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(workingCount: workingCount))
        .accessibilityHint("Collapses or expands this workspace's chats")
    }

    /// Exposed so the workspace-folder hierarchy tests pin the contrast step
    /// without re-parsing the view body.
    var titleColor: Color { HerdrTheme.text }
    var folderIconColor: Color { HerdrTheme.folder }

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

/// A machine heading (`.proj`): a 32pt row with the machine glyph and count.
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
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 8) {
                    ZStack {
                        Image(systemName: "desktopcomputer")
                            .herdrFont(size: 15, relativeTo: .caption)
                            .foregroundStyle(HerdrTheme.iconTint)
                            .opacity(isHovering ? 0 : 1)
                        Image(systemName: "chevron.right")
                            .herdrFont(size: 10, weight: .semibold, relativeTo: .caption2)
                            .foregroundStyle(HerdrTheme.iconTint)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(isHovering ? 1 : 0)
                    }
                    .frame(width: 18)
                    .animation(.snappy, value: isExpanded)
                    .accessibilityHidden(true)

                    Text(machine.name)
                        .herdrFont(size: SidebarMetrics.projectLabelSize, weight: SidebarMetrics.projectLabelWeight, relativeTo: .subheadline)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)

                    Spacer()

                    if state == .live || state == .demo {
                        Text("\(paneCount)")
                            .herdrFont(size: SidebarMetrics.metaLabelSize)
                            .monospacedDigit()
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .fixedSize()
                    } else {
                        Text(state.title)
                            .herdrFont(size: SidebarMetrics.metaLabelSize)
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
                    .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small))
                    .disabled(!canCreateWorkspace)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .help("New workspace on \(machine.name)")
                    .accessibilityIdentifier("sidebar-machine-new-workspace-\(machine.id)")
            }
        }
        .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
        .padding(.trailing, 4)
        .herdrRowBackground(selected: false, hovered: isHovering)
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A tab inside a folder group (`.tabl`): "⌄ Agents · 3".
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
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .herdrFont(size: 9, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(folderColor)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)
                    .frame(width: 10)

                if let tabColor {
                    Image(systemName: tabColor.symbol)
                        .herdrFont(size: SidebarMetrics.tabLabelSize)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityLabel(tabColor.defaultLabel)
                }
                Text("\(tab.label) · \(tab.paneCount)")
                    .herdrFont(
                        size: SidebarMetrics.tabLabelSize,
                        weight: attentionStatus != nil ? .medium : .regular,
                        relativeTo: .caption
                    )
                    .monospacedDigit()
                    .foregroundStyle(attentionStatus != nil ? HerdrTheme.text : HerdrTheme.tertiaryText)
                    .lineLimit(1)

                Spacer()

                if workingCount > 0 {
                    Text("\(workingCount) working")
                        .herdrFont(size: SidebarMetrics.metaLabelSize)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.working)
                        .fixedSize()
                }
            }
            .padding(.leading, SidebarMetrics.tabRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.tabRowHeight)
            .contentShape(Rectangle())
            .background(tabColor?.rowBackground(hovering: isHovering) ?? (isHovering ? HerdrTheme.hoverFill : .clear), in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .padding(.horizontal, SidebarMetrics.folderCardInset)
        }
        .buttonStyle(.plain)
        .sidebarFolderStrip(.middle)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this tab's chats")
    }

    private var folderColor: Color {
        if let attentionStatus { return attentionStatus.color }
        return workingCount > 0 ? HerdrTheme.working : HerdrTheme.iconTint
    }

    private var accessibilityLabel: String {
        let attention = attentionStatus.map { ", \($0.title)" } ?? ""
        let working = workingCount > 0 ? ", \(workingCount) working" : ""
        return "\(tab.label), \(tab.paneCount) panes\(attention)\(working)"
    }
}

/// A MonoCode session card.
///
/// `.full` (Unread, Starred, Recents): agent and status, the title, then
/// machine · workspace. `.compact` (inside a folder group): the title over its
/// status. Idle and shell sessions render quietly.
struct SidebarChatRow: View {
    struct RecentContext {
        let machine: String
        let workspace: String
        let tab: String

        var accessibilityLabel: String {
            "Machine: \(machine), workspace: \(workspace), tab: \(tab)"
        }
    }

    enum CardStyle: Equatable {
        case compact
        /// A full card with its "machine · workspace" line.
        case full(location: String)
    }

    let pane: HerdrPane
    var recentContext: RecentContext?
    var style: CardStyle = .compact
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
            HStack(alignment: .top, spacing: 6) {
                if differentiateWithoutColor, let tabColor {
                    Image(systemName: tabColor.symbol)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityHidden(true)
                }
                if let location = fullCardLocation {
                    fullCard(location: location)
                } else {
                    compactCard
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .padding(.vertical, isFullCard ? SidebarMetrics.cardVerticalPadding : SidebarMetrics.compactCardVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.chatRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                if isSelected, let tabColor {
                    RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                        .strokeBorder(tabColor.swatch.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(dragHelp)
        .accessibilityIdentifier("sidebar-pane-\(pane.id)")
        .accessibilityElement(children: toggleStar == nil ? .combine : .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(canDragConversation
            ? "Opens this chat. Drag it onto another prompt to quote its conversation."
            : "Opens this pane.")
        .overlay(alignment: .topLeading) { disclosureControl }
        .modifier(SidebarConversationDragModifier(pane: pane))
    }

    private var fullCardLocation: String? {
        if let recentContext { return "\(recentContext.machine) · \(recentContext.workspace)" }
        if case let .full(location) = style { return location }
        return nil
    }

    private var isFullCard: Bool { fullCardLocation != nil }

    /// Idle and shell sessions step back: a medium title in secondary ink.
    private var isQuiet: Bool {
        !isSelected && !isUnread && !isManuallyUnread
            && (pane.agentStatus == .idle || pane.agentStatus == .unknown)
    }

    private var showsStatus: Bool {
        isManuallyUnread || describesLastActivity || pane.agentStatus.needsAttention || pane.agentStatus == .working
    }

    private var cardStatus: SidebarCardStatus {
        SidebarCardStatus(
            status: pane.agentStatus,
            since: since,
            describesLastActivity: describesLastActivity,
            isManuallyUnread: isManuallyUnread
        )
    }

    private func fullCard(location: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarTone.agentSymbol(for: pane))
                        .herdrFont(size: 13)
                        .foregroundStyle(HerdrTheme.iconTint)
                        .accessibilityHidden(true)
                    Text(pane.displayAgentName)
                        .lineLimit(1)
                }
                .herdrFont(size: SidebarMetrics.metaLabelSize)
                .foregroundStyle(metaColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsStatus { cardStatus }
            }
            titleLine
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .herdrFont(size: 11)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
                Text(location)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(recentContext?.accessibilityLabel ?? location)
            }
            .herdrFont(size: SidebarMetrics.metaLabelSize)
            .foregroundStyle(metaColor)
            contextLines
        }
    }

    /// Meta text lifts to secondary on a selected row: over sidebar glass,
    /// tertiary on the 10% selection falls under 4.5:1 on bright desktops.
    private var metaColor: Color {
        isSelected ? HerdrTheme.secondaryText : HerdrTheme.tertiaryText
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLine
            if showsStatus || isQuiet {
                cardStatus
            }
            contextLines
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(pane.displayTitle)
                .herdrFont(size: SidebarMetrics.chatLabelSize, weight: isQuiet ? .medium : .semibold, relativeTo: .subheadline)
                .foregroundStyle(isQuiet ? HerdrTheme.secondaryText : HerdrTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hierarchy, hierarchy.childCount > 0 {
                Text("\(hierarchy.childCount)")
                    .herdrFont(size: SidebarMetrics.metaLabelSize)
                    .monospacedDigit()
                    .foregroundStyle(metaColor)
                    .help("\(hierarchy.childCount) child sessions")
                    .fixedSize()
            }
            starControl
            if isUnread {
                Circle()
                    .fill(HerdrTheme.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
        }
    }

    @ViewBuilder
    private var contextLines: some View {
        if let workspaceLabel = hierarchy?.workspaceLabel {
            Label(workspaceLabel, systemImage: "folder")
                .herdrFont(size: SidebarMetrics.metaLabelSize)
                .foregroundStyle(metaColor)
                .lineLimit(1)
                .help("Workspace: \(workspaceLabel)\n\(pane.displayPath)")
        }
        if let parentContext {
            Text(parentContext)
                .herdrFont(size: SidebarMetrics.metaLabelSize)
                .foregroundStyle(metaColor)
                .lineLimit(1)
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
            .herdrFont(size: 10, weight: .semibold)
            .foregroundStyle(HerdrTheme.iconTint)
            .buttonStyle(.plain)
            .frame(width: 20, height: SidebarMetrics.chatRowHeight)
            .contentShape(Rectangle())
            .padding(.leading, SidebarMetrics.chatRowLeadingPadding - 4 + hierarchyIndent)
            .padding(.top, 2)
            .accessibilityIdentifier("sidebar-session-disclosure-\(pane.id)")
            .accessibilityValue(hierarchy.isExpanded ? "expanded" : "collapsed")
            .help("\(hierarchy.isExpanded ? "Collapse" : "Expand") \(hierarchy.childCount) child sessions")
        }
    }

    private var hierarchyIndent: CGFloat { CGFloat(min(hierarchy?.depth ?? 0, 6)) * 16 }

    private var leadingPadding: CGFloat {
        let belongsToFamily = (hierarchy?.depth ?? 0) > 0 || (hierarchy?.childCount ?? 0) > 0
        return SidebarMetrics.chatRowLeadingPadding + hierarchyIndent + (belongsToFamily ? 16 : 0)
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
                    .foregroundStyle(isStarred ? HerdrTheme.tertiaryText : HerdrTheme.iconTint)
                    .frame(width: SidebarMetrics.starSlotWidth, height: 16)
                    // Keep a 28pt target without making the title line taller.
                    .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                    .contentShape(Rectangle())
                    .padding(.vertical, -6)
                    .padding(.horizontal, -6)
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
                .foregroundStyle(HerdrTheme.tertiaryText)
                .frame(width: SidebarMetrics.starSlotWidth)
        } else {
            Color.clear.frame(width: SidebarMetrics.starSlotWidth, height: 1)
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

    private var dragHelp: String {
        guard canDragConversation else { return accessibilityLabel }
        return "\(accessibilityLabel)\nDrag onto another prompt to add this conversation as context."
    }

    private var canDragConversation: Bool {
        pane.supportsPiSemanticChat
            && pane.piSemantic?.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var rowBackground: Color {
        if let tabColor { return tabColor.rowBackground(selected: isSelected, hovering: isHovering) }
        if isSelected { return HerdrTheme.selectedFill }
        return isHovering ? HerdrTheme.hoverFill : .clear
    }
}

private struct SidebarConversationDragModifier: ViewModifier {
    let pane: HerdrPane

    @ViewBuilder
    func body(content: Content) -> some View {
        if pane.supportsPiSemanticChat,
           pane.piSemantic?.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            content.draggable(ConversationContextTransfer(pane: pane)) {
                Label(pane.displayTitle, systemImage: "bubble.left.and.text.bubble.right")
                    .padding(8)
                    .herdrCard(radius: HerdrTheme.Radius.composer, fill: HerdrTheme.elevated)
                    .accessibilityLabel("Conversation context from \(pane.displayTitle)")
            }
        } else {
            content
        }
    }
}
