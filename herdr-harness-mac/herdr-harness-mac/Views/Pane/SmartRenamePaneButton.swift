import SwiftUI

struct SmartRenamePaneButton: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        if pane.piSemantic?.sessionID != nil {
            Button(model.smartRenamingPaneIDs.contains(pane.id) ? "Renaming…" : "Smart Rename",
                   systemImage: "sparkles") {
                Task { await model.smartRename(pane) }
            }
            .disabled(!model.canControl(machineID: pane.machineID) || model.smartRenamingPaneIDs.contains(pane.id))
            .help("Generate a short title from this Pi conversation in a separate quick AI session")
            .accessibilityIdentifier("pane-smart-rename")
        }
    }
}
