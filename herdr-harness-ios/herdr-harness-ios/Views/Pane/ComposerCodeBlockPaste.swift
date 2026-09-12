import SwiftUI
import UIKit

/// User-initiated literal code paste for the iOS composer.
/// Clipboard contents are read only when the Paste code menu action invokes `paste`.
enum ComposerCodeBlockPaste {
    static func fenced(_ text: String) -> String {
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    static func appending(_ text: String, to draft: String) -> String {
        draft + (draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n") + fenced(text)
    }

    @MainActor
    @discardableResult
    static func paste(
        into binding: Binding<String>,
        pasteboard: UIPasteboard = .general
    ) -> Bool {
        guard let text = pasteboard.string, !text.isEmpty else { return false }
        binding.wrappedValue = appending(text, to: binding.wrappedValue)
        return true
    }
}
