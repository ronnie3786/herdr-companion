import Foundation

/// View-owned state for the transient Last prompt sheet. Keeping this state
/// above `Menu` matters: the menu tears down its presented content after an
/// action, while the pane remains mounted long enough to own the sheet.
struct LastPromptPeekPresentation: Equatable {
    var message: PiUserMessage?

    mutating func present(_ message: PiUserMessage?) {
        guard let message else { return }
        self.message = message
    }

    mutating func copy(using write: (String) -> Void) {
        guard let message else { return }
        write(message.text)
    }

    mutating func dismiss() {
        message = nil
    }
}
