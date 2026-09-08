import AppKit
import SwiftUI

struct CopyPaneIDButton: View {
    let pane: HerdrPane

    var body: some View {
        Button("Copy workspace pane ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pane.paneID, forType: .string)
        }
        .accessibilityIdentifier("copy-workspace-pane-id")
    }
}
