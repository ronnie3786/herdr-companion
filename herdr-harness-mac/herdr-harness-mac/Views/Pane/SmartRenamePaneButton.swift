import SwiftUI

struct SmartRenamePaneButton: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        Button(model.smartRenamingPaneIDs.contains(pane.id) ? "Renaming…" : "Smart Rename",
               systemImage: "sparkles") {
            Task { await model.smartRename(pane) }
        }
        .disabled(!model.canControl(machineID: pane.machineID) || model.smartRenamingPaneIDs.contains(pane.id))
        .help("Generate a short title from this pane's conversation, terminal output, or workspace context in a separate quick AI session")
        .accessibilityIdentifier("pane-smart-rename")
    }
}
