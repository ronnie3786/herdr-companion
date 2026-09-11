import Foundation

enum ChatTabColorFilter {
    /// Apply before building priority groups or session families: an uncolored
    /// parent/child must never pull a nonmatching chat back into a color filter.
    static func workspaces(_ workspaces: [HerdrWorkspace], tabIDs: Set<String>?) -> [HerdrWorkspace] {
        guard let tabIDs else { return workspaces }
        return workspaces.compactMap { workspace in
            var copy = workspace
            copy.panes = workspace.panes.filter { tabIDs.contains($0.scopedTabID) }
            copy.tabs = workspace.tabs.filter { tabIDs.contains($0.id) }
            return copy.panes.isEmpty ? nil : copy
        }
    }
}
