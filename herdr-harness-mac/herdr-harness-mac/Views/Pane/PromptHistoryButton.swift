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
        .labelStyle(.iconOnly)
        .foregroundStyle(HerdrTheme.mist)
        .frame(width: 30, height: 28)
        .buttonStyle(.plain)
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
