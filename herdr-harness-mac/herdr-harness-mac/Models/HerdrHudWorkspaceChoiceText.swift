import Foundation

/// Presentation text for one main-workspace destination. Identity always stays
/// the raw workspace ID; a label is shown beside it so two workspaces that
/// share a label remain distinguishable in menus, the selected destination,
/// and accessibility text.
enum HerdrHudWorkspaceChoiceText {
    static func title(label: String, workspaceID: String) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != workspaceID else { return workspaceID }
        return "\(label) — \(workspaceID)"
    }

    static func title(for workspace: HerdrWorkspace) -> String {
        title(label: workspace.label, workspaceID: workspace.workspaceID)
    }
}
