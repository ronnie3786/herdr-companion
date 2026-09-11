import AppKit

/// A newly inserted SwiftUI TextField can lose its onAppear focus request to
/// the sidebar's existing key-view loop. Claim the native field editor only
/// after this control has joined its window and that layout turn has finished.
final class ChatColorLabelTextField: NSTextField {
    private var focusRequestPending = false
    private var hasAcquiredFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocus()
    }

    func requestInitialFocus() {
        guard let window, !hasAcquiredFocus, !focusRequestPending else { return }
        focusRequestPending = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.focusRequestPending = false
            guard let window, self.window === window, !self.hasAcquiredFocus else { return }
            if window.makeFirstResponder(self) {
                self.currentEditor()?.selectedRange = NSRange(location: 0, length: self.stringValue.utf16.count)
                self.hasAcquiredFocus = true
            }
        }
    }
}
