import SwiftUI

struct PaneActionsMenu: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @Binding var selectedMode: PaneDetailMode
    var gitIsAvailable = false
    var isPiCompacting = false
    var isStartingNewPiChat = false
    var startNewPiChat: (() -> Void)? = nil
    @State private var isConfirmingClose = false
    @State private var isConfirmingEndPiAndClose = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        paneActionsMenu
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
            .accessibilityIdentifier("pane-mode-toggle")
    }

    private var paneActionsMenu: some View {
        Menu("Pane actions", systemImage: "ellipsis.circle") {
            viewModeSection
            Section("Focus and control") { focusActions }
            Section("Pi session") { piSessionActions }
            Section("Pane") { paneManagementActions }
            Section("Close") { closeAction }
        }
    }

    private var viewModeSection: some View {
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
                .accessibilityLabel("\(mode.label) view")
                .accessibilityIdentifier("pane-mode-\(mode.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var focusActions: some View {
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

    @ViewBuilder
    private var piSessionActions: some View {
        if pane.supportsPiSemanticChat || isPiPane {
            Button(isStartingNewPiChat ? "Starting new Pi chat…" : "New Pi chat", systemImage: "plus.bubble") {
                if let startNewPiChat { startNewPiChat() }
                else { Task { await model.startNewPiChat(in: pane) } }
            }
            .accessibilityIdentifier("pane-action-new-pi-chat")
            .disabled(piSessionMutationIsDisabled)

            Button("End Pi session", systemImage: "stop.circle.fill", role: .destructive) {
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

    private var piSessionMutationIsDisabled: Bool {
        isStartingNewPiChat || !Self.piSessionMutationsEnabled(
            canControl: model.canControl(machineID: pane.machineID),
            isCompacting: isPiCompacting
        )
    }

    static func piSessionMutationsEnabled(canControl: Bool, isCompacting: Bool) -> Bool {
        canControl && !isCompacting
    }

    @ViewBuilder
    private var paneManagementActions: some View {
        SmartRenamePaneButton(model: model, pane: pane)
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

    private var closeAction: some View {
        Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
            isConfirmingClose = true
        }
        .disabled(!model.canControl(machineID: pane.machineID))
    }

    private var isPiPane: Bool {
        [pane.agent, pane.displayAgent].contains {
            $0?.caseInsensitiveCompare("pi") == .orderedSame
        }
    }

    private var availableModes: [PaneDetailMode] {
        PaneDetailMode.allCases.filter { mode in
            (mode != .chat || pane.supportsPiSemanticChat)
                && (mode != .git || gitIsAvailable)
        }
    }
}
