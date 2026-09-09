import SwiftUI

struct WorkspaceSearchField: View {
    @Binding var text: String
    var placeholder: String = "Filter spaces"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? HerdrTheme.accent : HerdrTheme.mist)

            TextField(placeholder, text: $text)
                // Plain style, or AppKit draws its own bezel inside our chrome.
                .textFieldStyle(.plain)
                .herdrFont(size: 12, relativeTo: .subheadline)
                .foregroundStyle(HerdrTheme.text)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .herdrHitTarget(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .help("Clear filter")
                .accessibilityLabel("Clear workspace filter")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, text.isEmpty ? 10 : 3)
        .frame(minHeight: 34)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isFocused ? HerdrTheme.accent.opacity(0.65) : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }
}
