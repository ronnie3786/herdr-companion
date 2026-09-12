import SwiftUI

struct WorkspaceSearchField: View {
    @Binding var text: String
    var placeholder: String = "filter spaces"
    /// Defaults to the visible placeholder so reused search fields keep their
    /// VoiceOver purpose aligned; callers may still provide more specific copy.
    var accessibilityLabel: String? = nil
    /// Spelled out rather than derived from `accessibilityLabel`: composing it
    /// produced "Clear filter spaces".
    var clearAccessibilityLabel: String = "Clear workspace filter"
    var monospaced = true
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? HerdrTheme.accent : HerdrTheme.mist)

            TextField(placeholder, text: $text)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(HerdrTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityLabel(accessibilityLabel ?? placeholder)

            if !text.isEmpty {
                Button(clearAccessibilityLabel, systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(HerdrTheme.mist)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, text.isEmpty ? 13 : 3)
        .frame(minHeight: 48)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }
}
