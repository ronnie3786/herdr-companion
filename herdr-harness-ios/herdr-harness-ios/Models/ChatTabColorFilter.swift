import Foundation

enum ChatTabColorFilter {
    /// Apply before priority grouping so no excluded tab can be pulled back
    /// into the result by another presentation rule.
    static func workspaces(
        _ workspaces: [HerdrWorkspace],
        tabIDs: Set<String>?
    ) -> [HerdrWorkspace] {
        guard let tabIDs else { return workspaces }
        return workspaces.compactMap { workspace in
            var copy = workspace
            copy.panes = workspace.panes.filter { tabIDs.contains($0.scopedTabID) }
            copy.tabs = workspace.tabs.filter { tabIDs.contains($0.id) }
            return copy.panes.isEmpty ? nil : copy
        }
    }
}
