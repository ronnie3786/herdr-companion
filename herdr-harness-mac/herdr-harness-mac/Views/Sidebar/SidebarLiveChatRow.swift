import SwiftUI

/// Tree snapshots own grouping and order, not the latest title or agent state.
/// Observe the pane at the row boundary so lazy-list reuse cannot retain a
/// stale "Working" label after the HUD has received the completed state.
struct SidebarLiveChatRow<Content: View>: View {
    let model: HerdrAppModel
    let paneID: String
    @ViewBuilder let content: (HerdrPane) -> Content

    var body: some View {
        if let pane = model.pane(id: paneID) {
            content(pane)
        }
    }
}
