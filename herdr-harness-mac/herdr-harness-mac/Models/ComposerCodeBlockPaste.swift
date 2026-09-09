import AppKit

/// Pastes literal Markdown fences without trimming or executing clipboard text.
enum ComposerCodeBlockPaste {
    /// A popover may become the key window before its Paste action runs. Keep
    /// the originating editor weakly and only reuse it while the draft still
    /// matches, so paste retains selection and undo without touching a new field.
    @MainActor
    final class EditorSelection {
        weak var editor: NSTextView?
        let draft: String
        let range: NSRange

        init?(editor: NSTextView, draft: String) {
            guard editor.isEditable, editor.string == draft else { return nil }
            self.editor = editor
            self.draft = draft
            range = editor.selectedRange()
        }

        func destination(for currentDraft: String) -> (NSTextView, NSRange)? {
            guard currentDraft == draft, let editor,
                  editor.isEditable, editor.string == currentDraft else { return nil }
            return (editor, range)
        }
    }

    @MainActor
    static func captureSelection(for draft: String) -> EditorSelection? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        return EditorSelection(editor: editor, draft: draft)
    }

    static func fenced(_ text: String) -> String {
        // A longer fence keeps a pasted snippet containing its own fences intact.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    static func inserting(_ text: String, into draft: String, selection: NSRange? = nil) -> String {
        let source = draft as NSString
        let range = selection ?? NSRange(location: source.length, length: 0)
        guard range.location != NSNotFound, range.location <= source.length,
              range.length <= source.length - range.location else { return draft }
        let prefix = source.substring(to: range.location)
        let suffix = source.substring(from: NSMaxRange(range))
        return prefix + (prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n")
            + fenced(text) + (suffix.isEmpty || suffix.hasPrefix("\n") ? "" : "\n") + suffix
    }

    @MainActor
    @discardableResult
    static func paste(
        into draft: inout String,
        pasteboard: NSPasteboard = .general,
        selection: EditorSelection? = nil
    ) -> Bool {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        // Check the editor belongs to this draft. A click can leave another field
        // focused, and it must never receive the clipboard content by accident.
        let currentEditor = NSApp.keyWindow?.firstResponder as? NSTextView
        let destination = selection?.destination(for: draft)
            ?? currentEditor.flatMap { editor -> (NSTextView, NSRange)? in
                guard editor.isEditable, editor.string == draft else { return nil }
                return (editor, editor.selectedRange())
            }
        if let (editor, range) = destination {
            let draftLength = (draft as NSString).length
            guard range.location != NSNotFound, range.location <= draftLength,
                  range.length <= draftLength - range.location else { return false }
            let result = inserting(text, into: draft, selection: range)
            let unchangedLength = (draft as NSString).length - range.length
            let insertedLength = (result as NSString).length - unchangedLength
            guard insertedLength >= 0 else { return false }
            let insertion = (result as NSString).substring(with: NSRange(location: range.location, length: insertedLength))
            editor.insertText(insertion, replacementRange: range)
            draft = editor.string
        } else {
            draft = inserting(text, into: draft)
        }
        return true
    }
}
