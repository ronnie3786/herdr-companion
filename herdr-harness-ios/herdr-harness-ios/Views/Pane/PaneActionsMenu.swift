import SwiftUI

struct PaneActionsMenu: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @Binding var selectedMode: PaneDetailMode
    let gitIsAvailable: Bool
    var isPiCompacting = false
    /// Mirrors the Mac's `PaneSessionHeader` parameters. Defaulted so the flag
    /// and the action can be added at the single call site without touching
    /// anything else.
    var showsPiSessionSummary = false
    var summarizePiSession: () -> Void = { }
    @State private var isConfirmingClose = false
    @State private var isConfirmingEndPiAndClose = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        Menu("Pane actions", systemImage: "ellipsis.circle") {
            Section("View") {
                ForEach(availableModes) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        Label(
                            mode.label,
                            systemImage: selectedMode == mode ? "checkmark.circle.fill" : mode.symbol
                        )
                    }
                    .disabled(!modeIsEnabled(mode))
                    .accessibilityLabel(
                        selectedMode == mode ? "\(mode.label) view, selected" : "\(mode.label) view"
                    )
                    .accessibilityHint(modeAccessibilityHint(mode))
                    .accessibilityIdentifier("pane-action-mode-\(mode.rawValue)")
                }
            }

            Section("Chat organization") {
                Button(
                    isStarred ? "Unstar chat" : "Star chat",
                    systemImage: isStarred ? "star.fill" : "star"
                ) {
                    model.toggleStarredChat(pane.id)
                }
                .accessibilityIdentifier("pane-action-star")

                ChatTabColorMenu(store: model.chatTabColors, tabID: pane.scopedTabID)
            }

            Section("Focus and control") {
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

            }

            Section("Pi session") {
                // Gated on the Pi session id, not on `supportsPiSemanticChat`: the
                // summary reads the transcript off disk in a separate headless
                // session, so a pane whose semantic bridge is no longer connected
                // can still be summarized.
                if showsPiSessionSummary {
                    Button("Summarize Pi session", systemImage: "list.bullet.clipboard", action: summarizePiSession)
                        // The run is dispatched to the pane's machine, not the
                        // primary connection, so this row checks that machine.
                        .disabled(!model.canControl(machineID: pane.machineID))
                        .accessibilityIdentifier("pane-summarize-pi-session")
                        .accessibilityHint("Opens a short summary generated in a separate headless Pi session")
                }

                if pane.supportsPiSemanticChat || [pane.agent, pane.displayAgent].contains(where: { $0?.caseInsensitiveCompare("pi") == .orderedSame }) {
                    Button("Reload Pi extensions", systemImage: "arrow.clockwise") {
                        Task { await model.reloadPiSession(in: pane) }
                    }
                    .accessibilityIdentifier("pane-action-reload-pi-session")
                    .disabled(piSessionMutationIsDisabled)

                    Button("Compact Pi chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                        Task { await model.compactPiChat(in: pane) }
                    }
                    .accessibilityIdentifier("pane-action-compact-pi-chat")
                    .disabled(piSessionMutationIsDisabled)

                    Button("New Pi chat", systemImage: "plus.bubble") {
                        Task { await model.startNewPiChat(in: pane) }
                    }
                    .accessibilityIdentifier("pane-action-new-pi-chat")
                    .disabled(piSessionMutationIsDisabled)

                    Button("End Pi session", systemImage: "xmark.bubble", role: .destructive) {
                        Task { await model.endPiSession(in: pane) }
                    }
                    .accessibilityIdentifier("pane-action-end-pi-session")
                    .disabled(piSessionMutationIsDisabled)

                    Button("End Pi & close pane", systemImage: "xmark.rectangle", role: .destructive) {
                        isConfirmingEndPiAndClose = true
                    }
                    .accessibilityIdentifier("pane-action-end-pi-and-close-pane")
                    .disabled(piSessionMutationIsDisabled)
                }

            }

            Section("Pane") {
                Button("Rename pane", systemImage: "pencil") {
                    renameText = pane.displayTitle
                    isRenaming = true
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

            }

            Section("Close") {
                Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                    isConfirmingClose = true
                }
                .disabled(!model.canControl(machineID: pane.machineID))
            }
        }
        .disabled(model.paneLifecycleBusyIDs.contains(pane.id))
        .confirmationDialog(
            "Close this pane?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Close pane", role: .destructive) {
                Task { await model.close(pane) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the process running in \(pane.displayTitle). Closing the last pane also removes its tab, and may remove its workspace. Use End Pi & close pane to keep the tab.")
        }
        .confirmationDialog(
            "End Pi and close this pane?",
            isPresented: $isConfirmingEndPiAndClose,
            titleVisibility: .visible
        ) {
            Button("End Pi & close pane", role: .destructive) {
                Task { await model.endPiSessionAndClosePane(in: pane) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Ends Pi and closes \(pane.displayTitle), keeping this tab and workspace open. If this is the tab’s last pane, a fresh shell is created first. Saved conversations are not deleted.")
        }
        .alert("Rename pane", isPresented: $isRenaming) {
            TextField("Pane name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task { await model.rename(pane, label: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This label is shared with Herdr on your Mac.")
        }
        .accessibilityValue("\(selectedMode.label) view")
        .accessibilityIdentifier("pane-mode-toggle")
    }

    private var availableModes: [PaneDetailMode] {
        [.chat, .git, .terminal, .skills]
    }

    private func modeAccessibilityHint(_ mode: PaneDetailMode) -> String {
        if mode == .chat, !pane.supportsPiSemanticChat {
            return "Native chat is unavailable for this pane"
        }
        if mode == .git, !gitIsAvailable {
            return "Git is unavailable until this workspace's repository is confirmed"
        }
        return "Shows the \(mode.label) view for this pane"
    }

    private var isStarred: Bool {
        model.starredChatIDs.contains(pane.id)
    }

    private func modeIsEnabled(_ mode: PaneDetailMode) -> Bool {
        switch mode {
        case .chat:
            return pane.supportsPiSemanticChat
        case .git:
            return gitIsAvailable
        case .terminal, .skills:
            return true
        }
    }

    private var piSessionMutationIsDisabled: Bool {
        !Self.piSessionMutationsEnabled(
            // Every one of these runs against the pane's own machine, and each
            // handler guards on it and returns silently. Gating on the
            // aggregate connection would leave the row tappable and mute.
            canControl: model.canControl(machineID: pane.machineID),
            isCompacting: isPiCompacting
        )
    }

    static func piSessionMutationsEnabled(canControl: Bool, isCompacting: Bool) -> Bool {
        canControl && !isCompacting
    }
}
