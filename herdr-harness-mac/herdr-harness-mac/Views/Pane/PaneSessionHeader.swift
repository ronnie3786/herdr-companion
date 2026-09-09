import SwiftUI

/// The pane's identity strip: who is running, how it is doing, and where.
///
/// Dead code on iOS — the navigation bar carried the title there. The Mac
/// window has no per-pane nav bar, so this is mounted as the real header above
/// the chat/terminal area.
struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let store: PiConversationStore
    var showsPiSessionSummary = false
    var summarizePiSession: () -> Void = { }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRenaming = false
    @State private var editingPane: HerdrPane?
    @State private var renameText = ""
    @FocusState private var titleIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsCompaction {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.working)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else {
                HerdrStatusDot(status: pane.agentStatus)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if isRenaming {
                        TextField("Chat title", text: $renameText)
                            .textFieldStyle(.plain)
                            .herdrFont(.subheadline, weight: .semibold)
                            .focused($titleIsFocused)
                            .background(InlineTitleClickAway { finishRename() })
                            .onSubmit { finishRename() }
                            .onExitCommand { finishRename(cancel: true) }
                            .onChange(of: titleIsFocused) { _, focused in
                                if !focused { finishRename() }
                            }
                            .onAppear { titleIsFocused = true }
                            .accessibilityIdentifier("pane-session-title-input")
                    } else {
                        Button {
                            renameText = pane.displayTitle
                            editingPane = pane
                            isRenaming = true
                        } label: {
                            Text(pane.displayTitle)
                                .herdrFont(.subheadline, weight: .semibold)
                                .foregroundStyle(HerdrTheme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canControl(machineID: pane.machineID))
                        .help("Edit chat title")
                        .accessibilityIdentifier("pane-session-title")
                    }

                    Button(isStarred ? "Unstar chat" : "Star chat",
                           systemImage: isStarred ? "star.fill" : "star") {
                        model.toggleStarredChat(pane.id)
                    }
                    .labelStyle(.iconOnly)
                    .herdrFont(.subheadline)
                    .foregroundStyle(isStarred ? HerdrTheme.accent : HerdrTheme.mist)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(isStarred ? "Remove from starred chats" : "Add to starred chats")
                    .accessibilityValue(isStarred ? "Starred" : "Not starred")
                    .accessibilityIdentifier("pane-session-star")

                    if showsAgentName {
                        Text(pane.displayAgentName.lowercased())
                            .herdrFont(.caption, weight: .medium)
                            .foregroundStyle(HerdrTheme.mist)
                            .fixedSize()
                    }

                    Text(sessionStatusTitle)
                        .herdrFont(.caption)
                        .foregroundStyle(sessionStatusColor)
                        .fixedSize()
                        .accessibilityIdentifier("pane-session-status")

                    if let lastActivityAt = pane.lastActivityAt {
                        // Re-renders on its own so an open chat's staleness does
                        // not freeze at whatever it read when the view mounted.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.stalenessLabel(since: lastActivityAt, now: context.date))
                                .herdrFont(.caption)
                                .foregroundStyle(Self.stalenessColor(since: lastActivityAt, now: context.date))
                                .accessibilityLabel(
                                    "Last activity \(HerdrTimestamp.spokenAge(since: lastActivityAt, now: context.date))"
                                )
                        }
                        .fixedSize()
                        .help("Last message in this chat")
                        .accessibilityIdentifier("pane-session-last-activity")
                    }
                }

                HStack(spacing: 7) {
                    Label(model.machines.first(where: { $0.id == pane.machineID })?.name ?? pane.machineID,
                          systemImage: "desktopcomputer")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .accessibilityIdentifier("pane-session-machine")
                    Text("·")
                        .foregroundStyle(HerdrTheme.mist)
                        .accessibilityHidden(true)
                    Text(locationName)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)

                    if !pane.displayPath.isEmpty {
                        Text("·")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mist)
                            .accessibilityHidden(true)

                        PanePathButton(
                            path: pane.displayPath,
                            reportFailure: reportPathOpenFailure
                        )
                        .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 8)

            PromptHistoryButton(
                history: model.promptHistory,
                paneID: pane.id,
                reuse: { model.setComposerDraft($0, for: pane.id) }
            )

            if showsPiSessionSummary {
                Button("Summarize", systemImage: "list.bullet.clipboard", action: summarizePiSession)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(HerdrTheme.elevated.opacity(0.35), in: .rect(cornerRadius: HerdrTheme.compactRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            .strokeBorder(HerdrTheme.separator, lineWidth: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canControl(machineID: pane.machineID))
                    .help("Summarize this Pi session and where you left off")
                    .accessibilityIdentifier("pane-summarize-pi-session")
                    .accessibilityHint("Opens a short summary generated in a separate headless Pi session")
            }

            Button("Focus on Mac", systemImage: pane.focused ? "scope" : "macwindow") {
                Task { await model.focus(pane) }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(pane.focused ? HerdrTheme.accent : HerdrTheme.mist)
            .frame(width: 30, height: 28)
            .contentShape(.rect)
            .buttonStyle(.plain)
            .disabled(!model.canControl(machineID: pane.machineID))
            .help(pane.focused ? "This pane is focused in terminal" : "Focus this pane in terminal")
            .accessibilityHint(pane.focused ? "This pane is focused on your Mac" : "Focuses this pane on your Mac")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.compactionActivity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.connection)
        .contextMenu {
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

    /// Goes quiet for a fresh chat and warms up once it has been sitting for a
    /// day, so staleness is scannable without reading the label.
    static func stalenessColor(since date: Date, now: Date = Date()) -> Color {
        now.timeIntervalSince(date) >= 86_400 ? HerdrTheme.muted : HerdrTheme.mist
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

    private var locationName: String {
        guard let workspace = model.workspace(containing: pane) else { return pane.workspaceID }
        guard let tab = workspace.tabs.first(where: { $0.id == pane.scopedTabID }) else {
            return workspace.label
        }
        return "\(workspace.label) · \(tab.label)"
    }

    private func reportPathOpenFailure(_ message: String) {
        model.toastMessage = message
    }

}
