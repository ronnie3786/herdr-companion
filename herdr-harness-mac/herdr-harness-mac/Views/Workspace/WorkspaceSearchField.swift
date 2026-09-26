import SwiftUI

/// MonoCode's search row: a bare 36pt band with a 12pt magnifier, no box.
struct WorkspaceSearchField: View {
    @Binding var text: String
    var placeholder: String = "Filter spaces"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(isFocused ? HerdrTheme.accent : HerdrTheme.iconTint)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text, prompt: Text(""))
                // Plain style, or AppKit draws its own bezel inside our chrome.
                .textFieldStyle(.plain)
                .herdrPlaceholder(placeholder, isVisible: text.isEmpty)
                .herdrFont(size: HerdrTheme.TextSize.small, relativeTo: .subheadline)
                .foregroundStyle(HerdrTheme.text)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small))
                .help("Clear filter")
                .accessibilityLabel("Clear workspace filter")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: HerdrTheme.ControlHeight.bar)
    }
}
