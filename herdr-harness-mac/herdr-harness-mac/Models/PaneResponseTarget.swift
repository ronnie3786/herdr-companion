import Foundation

/// Pin a rendered link to a machine and terminal, not just a reusable display ID.
struct PaneResponseTarget: Equatable, Sendable {
    let machineID: String
    let paneID: String
    let terminalID: String

    var scopedID: String { MachineScopedID.compose(machineID: machineID, rawID: paneID) }

    var url: URL {
        var components = URLComponents()
        components.scheme = "herdr"
        components.host = "pane"
        components.queryItems = [
            URLQueryItem(name: "pane_id", value: scopedID),
            URLQueryItem(name: "terminal_id", value: terminalID),
        ]
        return components.url!
    }
}
