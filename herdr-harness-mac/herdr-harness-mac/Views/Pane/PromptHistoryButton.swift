import SwiftUI

struct PromptHistoryButton: View {
    let history: PromptHistoryStore
    let paneID: String
    let reuse: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button("Prompt history", systemImage: "text.bubble.badge.clock") {
            isPresented = true
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: isPresented))
        .help("Browse, search, copy, or reuse your submitted prompts")
        .accessibilityIdentifier("pane-prompt-history")
        .popover(isPresented: $isPresented) {
            PromptHistoryView(entries: history.entries(for: paneID)) { text in
                reuse(text)
                isPresented = false
            }
        }
    }
}
