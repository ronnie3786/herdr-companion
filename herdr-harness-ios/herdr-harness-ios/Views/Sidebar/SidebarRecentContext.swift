import Foundation

struct SidebarRecentContext: Equatable {
    let machine: String
    let workspace: String
    let tab: String

    var accessibilityLabel: String {
        "Machine: \(machine), workspace: \(workspace), tab: \(tab)"
    }
}
