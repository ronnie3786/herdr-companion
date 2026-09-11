import AppKit
import SwiftUI

struct ChatColorLabelEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    let finish: (_ cancel: Bool) -> Void
    @Environment(\.herdrFontScale) private var fontScale

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ChatColorLabelTextField {
        let field = ChatColorLabelTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.textColor = NSColor(HerdrTheme.text)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Color label")
        field.setAccessibilityIdentifier(identifier)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: ChatColorLabelTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: ChatColorLegendRow.titleSize * fontScale.rawValue, weight: .medium)
        // Never replace the active field editor's text/selection during normal
        // observation updates, including an AI progress or sidebar refresh.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        field.requestInitialFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatColorLabelTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: ChatColorLabelTextField, coordinator: Coordinator) {
        coordinator.isFinished = true
        field.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChatColorLabelEditor
        var isFinished = false
        init(parent: ChatColorLabelEditor) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard !isFinished, let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            complete(cancel: false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                complete(cancel: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                complete(cancel: true)
                return true
            default:
                return false
            }
        }

        private func complete(cancel: Bool) {
            guard !isFinished else { return }
            isFinished = true
            parent.finish(cancel)
        }
    }
}
