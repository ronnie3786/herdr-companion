import AppKit

/// Resolves only the native editor under this composer's marker. A toolbar
/// click need not leave that editor (or even its window) as the key responder.
@MainActor
final class ComposerEditorTarget {
    weak var marker: NSView?

    func captureSelection(for draft: String) -> ComposerCodeBlockPaste.EditorSelection? {
        guard let marker, let root = marker.window?.contentView,
              !marker.isHiddenOrHasHiddenAncestor else { return nil }
        return findEditor(in: root, marker: marker).flatMap {
            ComposerCodeBlockPaste.EditorSelection(editor: $0, draft: draft)
        }
    }

    private func findEditor(in view: NSView, marker: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.isEditable, !editor.isHiddenOrHasHiddenAncestor,
           marker.convert(marker.bounds, to: nil).intersects(editor.convert(editor.visibleRect, to: nil)) {
            return editor
        }
        for child in view.subviews {
            if let editor = findEditor(in: child, marker: marker) { return editor }
        }
        return nil
    }
}
