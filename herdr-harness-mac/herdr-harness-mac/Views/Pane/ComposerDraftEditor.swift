import SwiftUI

/// A real scrolling editor once the draft grows beyond five visible lines.
/// The invisible text supplies the intrinsic height without making the editor
/// itself (and therefore the composer) claim all available vertical space.
struct ComposerDraftEditor: View {
    let placeholder: String
    @Binding var text: String
    var maximumVisibleLines = 5
    var pasteCode: (() -> Void)? = nil
    var editorTarget: ComposerEditorTarget? = nil
    /// Applied to the hidden sizing text and the editor alike, so the
    /// five-line scroll threshold matches what is drawn.
    var lineSpacing: CGFloat = 0

    var body: some View {
        Text(text.isEmpty ? " " : text + " ")
            .lineSpacing(lineSpacing)
            .lineLimit(1...maximumVisibleLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .lineSpacing(lineSpacing)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.visible)
                    .accessibilityLabel(placeholder)
                    .accessibilityIdentifier("composer-draft-editor")
                    .background(ComposerModifiedReturnHandler(text: $text, pasteCode: pasteCode, editorTarget: editorTarget))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(HerdrTheme.tertiaryText)
                                .padding(.top, 4)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
    }
}
