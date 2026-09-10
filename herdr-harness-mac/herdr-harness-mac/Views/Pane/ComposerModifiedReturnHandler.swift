import AppKit
import SwiftUI

/// Handle modified Return before SwiftUI dispatches key equivalents or submit
/// actions. At this point the native editor still owns focus and its selection.
/// The monitor is local to this app and only consumes events in this editor's
/// visible bounds, leaving other fields, ordinary Return, and IME input alone.
struct ComposerModifiedReturnHandler: NSViewRepresentable {
    @Binding var text: String
    var pasteCode: (() -> Void)? = nil
    var editorTarget: ComposerEditorTarget? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, pasteCode: pasteCode) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        editorTarget?.marker = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        context.coordinator.observeUndo()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.pasteCode = pasteCode
        editorTarget?.marker = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        coordinator.undoObservers.forEach(NotificationCenter.default.removeObserver)
        coordinator.undoObservers.removeAll()
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var text: Binding<String>
        var undoObservers: [NSObjectProtocol] = []
        var pasteCode: (() -> Void)?

        init(text: Binding<String>, pasteCode: (() -> Void)? = nil) {
            self.text = text
            self.pasteCode = pasteCode
        }

        private func owns(_ editor: NSTextView) -> Bool {
            guard let view, !view.isHiddenOrHasHiddenAncestor, view.window === editor.window else { return false }
            return view.convert(view.bounds, to: nil).intersects(editor.convert(editor.bounds.intersection(editor.visibleRect), to: nil))
        }

        func observeUndo() {
            // Native text-storage undo can omit SwiftUI's binding callback for
            // programmatic insertion. Sync only this editor's undo manager.
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let managerID = (notification.object as? UndoManager).map(ObjectIdentifier.init)
                    // NotificationCenter delivers this observer on .main.
                    MainActor.assumeIsolated {
                        guard let self, let editor = self.view?.window?.firstResponder as? NSTextView,
                              self.owns(editor), let manager = editor.undoManager,
                              managerID == ObjectIdentifier(manager) else { return }
                        self.text.wrappedValue = editor.string
                    }
                })
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, !view.isHiddenOrHasHiddenAncestor,
                  let window = view.window, event.window === window,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isEditable, !editor.hasMarkedText(), owns(editor)
            else { return event }
            let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v", let pasteCode {
                pasteCode()
                return nil
            }
            guard event.keyCode == 36 || event.keyCode == 76,
                  !modifiers.intersection([.shift, .option, .command]).isEmpty else { return event }
            editor.insertText("\n", replacementRange: editor.selectedRange())
            return nil
        }
    }
}
