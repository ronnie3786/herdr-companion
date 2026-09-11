import Foundation

struct PaneRetirementResponse: Decodable, Sendable {
    let ok: Bool
    let closedPaneID: String
    let workspaceID: String
    let tabID: String
    let nextPaneID: String
    let reservedShell: Bool
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok, reservedShell, warnings
        case closedPaneID = "closedPaneId"
        case workspaceID = "workspaceId"
        case tabID = "tabId"
        case nextPaneID = "nextPaneId"
    }
}
