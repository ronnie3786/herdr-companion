import SwiftUI

/// A folder landing page backed by an explicitly reserved native shell.
/// Ordinary idle terminals never enter this state.
struct ReservedShellView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    var openPane: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label("No open chats", systemImage: "folder")
        } description: {
            VStack(spacing: 8) {
                Text("Your tab and workspace are ready for something new.")
                if !pane.displayPath.isEmpty {
                    Text(pane.displayPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        } actions: {
            VStack(spacing: 12) {
                Button("New Pi chat", systemImage: "plus.bubble", action: startPi)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reserved-shell-new-pi")
                Button("Open shell", systemImage: "terminal", action: openShell)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reserved-shell-open")
                if model.paneLifecycleBusyIDs.contains(pane.id) {
                    ProgressView("Opening…")
                }
            }
            .disabled(!model.canControl(machineID: pane.machineID) || model.paneLifecycleBusyIDs.contains(pane.id))
        }
        .accessibilityIdentifier("reserved-shell-empty-state")
    }

    private func startPi() { open(startPi: true) }

    private func openShell() { open(startPi: false) }

    private func open(startPi: Bool) {
        Task {
            await model.openReservedShell(in: pane, startPi: startPi)
            if model.pane(id: pane.id)?.reservedShell == false { openPane?() }
        }
    }
}
