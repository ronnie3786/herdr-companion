import AppKit
import SwiftUI

/// Pastes literal Markdown fences without trimming or executing clipboard text.
enum ComposerCodeBlockPaste {
    /// A popover may become the key window before its Paste action runs. Keep
    /// the originating editor weakly and only reuse it while the draft still
    /// matches, so paste retains undo without touching a new field. The pasted
    /// block is appended regardless of the originating selection.
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
        into binding: Binding<String>,
        pasteboard: NSPasteboard = .general,
        selection: EditorSelection? = nil
    ) async -> Bool {
        // Leave the SwiftUI button transaction before native text editing. Its
        // deferred delegate write can otherwise restore the old draft and
        // invalidate native undo. Keyboard and CTA calls use this same path.
        await Task.yield()
        guard !Task.isCancelled,
              let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        // NSTextView insertion synchronously calls SwiftUI's binding setter.
        // Never hold an inout borrow of an observable draft across that call.
        let draft = binding.wrappedValue
        // Only use the owning composer's editor, never a different key field
        // whose text happens to match (especially when both drafts are empty).
        let destination = selection?.destination(for: draft)
        if let (editor, _) = destination {
            let end = (draft as NSString).length
            let result = inserting(text, into: draft)
            let insertion = (result as NSString).substring(from: end)
            editor.insertText(insertion, replacementRange: NSRange(location: end, length: 0))
            binding.wrappedValue = editor.string
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        } else {
            binding.wrappedValue = inserting(text, into: draft)
        }
        return true
    }
}
