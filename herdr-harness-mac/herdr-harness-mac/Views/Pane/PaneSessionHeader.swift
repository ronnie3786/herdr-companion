import SwiftUI

/// The pane's identity strip as a standalone 40pt bar (`PaneSessionTitle`).
/// Inside the main window the title goes to the window's title bar instead,
/// with the pane's actions in its ⋯ menu (`PaneSessionView`); machine,
/// location and folder live on the composer's context line.
struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let store: PiConversationStore

    var body: some View {
        HStack(spacing: 8) {
            PaneSessionTitle(model: model, pane: pane, store: store)
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: HerdrTheme.ControlHeight.titleBar)
        .herdrHairline(.bottom)
    }

    /// How stale the chat is, as a clock time for today and a date beyond it.
    ///
    /// A bare age ("3d") answers "how long" but not "since when", and the point
    /// of this label is deciding whether a chat is worth returning to. Today's
    /// chats get a wall-clock time, yesterday's get named, and anything older
    /// gets a date — each the shortest form that is still unambiguous.
    static func stalenessLabel(since date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday \(date.formatted(.dateTime.hour().minute()))"
        }
        if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now), date >= sixDaysAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// A step brighter while a chat is fresh, quieter once it has been sitting
    /// for a day, so staleness is scannable without reading the label.
    static func stalenessColor(since date: Date, now: Date = Date()) -> Color {
        now.timeIntervalSince(date) >= 86_400 ? HerdrTheme.tertiaryText : HerdrTheme.proseText
    }
}

/// The pane's identity in the title bar: a 6pt status dot, the editable
/// 13/600 title, star, agent, status and last activity.
struct PaneSessionTitle: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let store: PiConversationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRenaming = false
    @State private var editingPane: HerdrPane?
    @State private var renameText = ""
    @FocusState private var titleIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsCompaction {
                ProgressView()
                    .controlSize(.mini)
                    .tint(HerdrTheme.working)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(pane.agentStatus == .idle ? Color.clear : pane.agentStatus.color)
                    .overlay {
                        Circle().strokeBorder(pane.agentStatus.color, lineWidth: 1)
                    }
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(pane.agentStatus.title)
            }

            if isRenaming {
                TextField("Chat title", text: $renameText)
                    .textFieldStyle(.plain)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .focused($titleIsFocused)
                    .background(InlineTitleClickAway { finishRename() })
                    .onSubmit { finishRename() }
                    .onExitCommand { finishRename(cancel: true) }
                    .onChange(of: titleIsFocused) { _, focused in
                        if !focused { finishRename() }
                    }
                    .onAppear { titleIsFocused = true }
                    .frame(minWidth: 120)
                    .accessibilityIdentifier("pane-session-title-input")
            } else {
                Button {
                    renameText = pane.displayTitle
                    editingPane = pane
                    isRenaming = true
                } label: {
                    Text(pane.displayTitle)
                        .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .herdrHitTarget(minWidth: 0)
                }
                .buttonStyle(.herdrPlain)
                .disabled(!model.canControl(machineID: pane.machineID))
                .help("Edit chat title")
                .accessibilityIdentifier("pane-session-title")
            }

            Button(isStarred ? "Unstar chat" : "Star chat",
                   systemImage: isStarred ? "star.fill" : "star") {
                model.toggleStarredChat(pane.id)
            }
            .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small, tint: isStarred ? HerdrTheme.accent : HerdrTheme.iconTint))
            .fixedSize()
            .help(isStarred ? "Remove from starred chats" : "Add to starred chats")
            .accessibilityValue(isStarred ? "Starred" : "Not starred")
            .accessibilityIdentifier("pane-session-star")

            Group {
                if showsAgentName {
                    Text(pane.displayAgentName.lowercased())
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .fixedSize()
                }

                Text(sessionStatusTitle)
                    .foregroundStyle(sessionStatusColor)
                    .fixedSize()
                    .accessibilityIdentifier("pane-session-status")

                if let lastActivityAt = pane.lastActivityAt {
                    // Re-renders on its own so an open chat's staleness does
                    // not freeze at whatever it read when the view mounted.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(PaneSessionHeader.stalenessLabel(since: lastActivityAt, now: context.date))
                            .foregroundStyle(PaneSessionHeader.stalenessColor(since: lastActivityAt, now: context.date))
                            .accessibilityLabel(
                                "Last activity \(HerdrTimestamp.spokenAge(since: lastActivityAt, now: context.date))"
                            )
                    }
                    .fixedSize()
                    .help("Last message in this chat")
                    .accessibilityIdentifier("pane-session-last-activity")
                }
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .lineLimit(1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.compactionActivity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.connection)
        .contextMenu {
            ChatTabColorMenu(store: model.chatTabColors, tabID: pane.scopedTabID)
            SmartRenamePaneButton(model: model, pane: pane)
            CopyPaneIDButton(pane: pane)
        }
        .onChange(of: pane.id) { _, _ in finishRename() }
        .onDisappear { finishRename() }
        .accessibilityElement(children: .contain)
    }

    private var isStarred: Bool {
        model.starredChatIDs.contains(pane.id)
    }

    private func finishRename(cancel: Bool = false) {
        guard isRenaming else { return }
        isRenaming = false
        titleIsFocused = false
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = editingPane
        editingPane = nil
        guard !cancel, let target, !title.isEmpty, title != target.displayTitle else { return }
        Task { await model.rename(target, label: title) }
    }

    private var showsCompaction: Bool {
        store.connection == .connected && store.compactionActivity != nil
    }

    /// `displayTitle` falls back to the agent name when a pane has no label of
    /// its own, and "pi pi idle" reads like a rendering bug. Drop the duplicate.
    private var showsAgentName: Bool {
        pane.displayTitle.caseInsensitiveCompare(pane.displayAgentName) != .orderedSame
    }

    private var sessionStatusTitle: String {
        switch store.connection {
        case .bridgeOffline:
            "Offline"
        case .reconnecting:
            "Reconnecting"
        case .unavailable:
            "Unavailable"
        case .loading, .connected:
            showsCompaction ? "Compacting" : pane.agentStatus.compactTitle
        }
    }

    private var sessionStatusColor: Color {
        switch store.connection {
        case .bridgeOffline, .reconnecting, .unavailable:
            HerdrTheme.warning
        case .loading, .connected:
            showsCompaction ? HerdrTheme.working : pane.agentStatus.labelColor
        }
    }
}
