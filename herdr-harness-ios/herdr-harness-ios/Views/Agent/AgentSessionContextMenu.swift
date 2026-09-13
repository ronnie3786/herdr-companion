import SwiftUI
import UIKit

struct AgentSessionContextMenu: View {
    @Bindable var model: HerdrAppModel
    let session: AgentSession
    let openWorkspace: () -> Void
    let confirm: (AgentSessionAction) -> Void

    private var pane: HerdrPane { session.pane }
    private var canControl: Bool {
        model.canControl(machineID: pane.machineID) && !model.paneLifecycleBusyIDs.contains(pane.id)
    }

    var body: some View {
        Button("Rename", systemImage: "pencil") {
            confirm(AgentSessionAction(kind: .rename, pane: pane))
        }
        .disabled(!canControl)
        .accessibilityIdentifier("agent-action-rename")
        SmartRenamePaneButton(model: model, pane: pane)

        Button(
            model.starredChatIDs.contains(pane.id) ? "Unstar chat" : "Star chat",
            systemImage: model.starredChatIDs.contains(pane.id) ? "star.slash" : "star"
        ) {
            model.toggleStarredChat(pane.id)
        }
        .accessibilityIdentifier("agent-action-star")
        ChatTabColorMenu(store: model.chatTabColors, tabID: pane.scopedTabID)

        Divider()
        Button("Open workspace", systemImage: "folder", action: openWorkspace)
        Button("Copy pane ID", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = pane.paneID
            model.toastMessage = "Workspace pane ID copied"
        }
        Menu("Mac controls", systemImage: "desktopcomputer") {
            Button("Focus on Mac", systemImage: "scope") {
                Task { await model.focus(pane) }
            }
            Button("Focus on Mac + Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                Task { await model.focusAndZoom(pane) }
            }
            Button("Interrupt", systemImage: "stop.fill", role: .destructive) {
                confirm(AgentSessionAction(kind: .interrupt, pane: pane))
            }
        }
        .disabled(!canControl)
        Divider()
        Menu("Close session", systemImage: "xmark.bubble") {
            Button("End Pi & close pane", systemImage: "xmark.bubble", role: .destructive) {
                confirm(AgentSessionAction(kind: .endAndClose, pane: pane))
            }
            Button("Close pane", systemImage: "xmark.rectangle", role: .destructive) {
                confirm(AgentSessionAction(kind: .close, pane: pane))
            }
        }
        .disabled(!canControl)
    }
}
