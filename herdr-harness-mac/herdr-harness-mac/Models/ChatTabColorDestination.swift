import Foundation

/// A concrete tab target for a color shortcut's New chat action.
///
/// The display names make the menu readable, while the raw IDs keep tabs with
/// identical labels distinguishable across machines and workspaces.
struct ChatTabColorDestination: Equatable, Hashable, Identifiable, Sendable {
    let machineID: String
    let machineName: String
    let scopedWorkspaceID: String
    let rawWorkspaceID: String
    let workspaceLabel: String
    let scopedTabID: String
    let rawTabID: String
    let tabLabel: String
    let workspaceNumber: Int
    let tabNumber: Int
    let hasOpenPane: Bool

    var id: String { scopedTabID }

    var displayTitle: String {
        "\(machineName) · \(workspaceLabel) · \(tabLabel)"
    }

    var identityTitle: String {
        "IDs: \(machineID) / \(rawWorkspaceID) / \(rawTabID)"
    }

    var accessibilityTitle: String {
        "machine \(machineName) (\(machineID)), workspace \(workspaceLabel) (\(rawWorkspaceID)), tab \(tabLabel) (\(rawTabID))"
    }
}
