import Foundation

struct AgentSessionAction: Identifiable {
    enum Kind { case rename, interrupt, endAndClose, close }
    let id = UUID()
    let kind: Kind
    let pane: HerdrPane

    var title: String {
        switch kind {
        case .rename: "Rename session"
        case .interrupt: "Interrupt this session?"
        case .endAndClose: "End Pi and close this pane?"
        case .close: "Close this pane?"
        }
    }

    var buttonTitle: String {
        switch kind {
        case .rename: "Save"
        case .interrupt: "Interrupt"
        case .endAndClose: "End Pi & close pane"
        case .close: "Close pane"
        }
    }

    var message: String {
        switch kind {
        case .rename:
            "This label is shared with Herdr on your Mac."
        case .interrupt:
            "Sends Control-C to \(pane.displayTitle), interrupting its current work."
        case .endAndClose:
            "Ends Pi and closes \(pane.displayTitle), keeping its tab and workspace open. A fresh shell is created if needed. Saved conversations are not deleted."
        case .close:
            "Stops the process in \(pane.displayTitle). Closing the last pane also removes its tab and may remove its workspace."
        }
    }
}
