import AppKit
import SwiftUI

struct HerdrNoteRichEditor: View {
    @Binding var text: AttributedString
    let ink: Color
    let isEditable: Bool
    let focusRequest: UUID
    var onEscape: () -> Void = {}
    @State private var controls = Controls()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(HerdrNoteTextStyle.Format.allCases, id: \.self) { format in
                    Button { controls.editor?.toggle(format) } label: {
                        Image(systemName: format.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 30)
                            .background(ink.opacity(controls.active.contains(format) ? 0.14 : 0), in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.herdrPlain)
                    .accessibilityLabel(format.label)
                    .accessibilityAddTraits(controls.active.contains(format) ? .isSelected : [])
                    .accessibilityIdentifier("hud-note-format-\(format.rawValue)")
                    .help(format.label + shortcut(for: format))
                }
                Spacer(minLength: 0)
                Image(systemName: "textformat")
                    .foregroundStyle(ink.opacity(0.45))
                    .help("Type **bold**, *italic*, _italic_, or ~~strikethrough~~ to format as you write. Underline: ⌘U.")
                    .accessibilityLabel("Markdown shortcuts: double stars for bold, stars or underscores for italic, double tildes for strikethrough. Command U for underline.")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .disabled(!isEditable)
            Rectangle().fill(ink.opacity(0.10)).frame(height: 1)
            NativeEditor(text: $text, ink: NSColor(ink), isEditable: isEditable, focusRequest: focusRequest, controls: controls, onEscape: onEscape)
                .overlay(alignment: .topLeading) {
                    if text.characters.isEmpty {
                        Text("Jot something down…")
                            .font(.system(size: HerdrNoteTextStyle.fontSize))
                            .foregroundStyle(ink.opacity(0.45))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
        .foregroundStyle(ink)
        .background(ink.opacity(0.035), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func shortcut(for format: HerdrNoteTextStyle.Format) -> String {
        switch format {
        case .bold: " (⌘B)"
        case .italic: " (⌘I)"
        case .underline: " (⌘U)"
        case .strikethrough: ""
        }
    }

    @MainActor @Observable
    final class Controls {
        weak var editor: HerdrNoteTextView?
        var active: Set<HerdrNoteTextStyle.Format> = []

        func refresh() {
            guard let editor else { return }
            active = Set(HerdrNoteTextStyle.Format.allCases.filter(editor.isActive))
        }
    }

    private struct NativeEditor: NSViewRepresentable {
        @Binding var text: AttributedString
        let ink: NSColor
        let isEditable: Bool
        let focusRequest: UUID
        let controls: Controls
        let onEscape: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let editor = HerdrNoteTextView(frame: .zero)
            editor.isRichText = true
            editor.importsGraphics = false
            editor.allowsUndo = true
            editor.usesFontPanel = false
            editor.drawsBackground = false
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.textContainerInset = NSSize(width: 9, height: 12)
            editor.setAccessibilityLabel("Note body")
            editor.setAccessibilityIdentifier("hud-note-body")
            editor.delegate = context.coordinator
            editor.formatChanged = { [weak controls] in controls?.refresh() }
            controls.editor = editor
            scroll.documentView = editor
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.isUpdating = true
            defer { context.coordinator.isUpdating = false }
            guard let editor = scroll.documentView as? HerdrNoteTextView else { return }
            editor.onEscape = onEscape
            editor.ink = ink
            editor.insertionPointColor = ink
            editor.selectedTextAttributes = [.backgroundColor: ink.withAlphaComponent(0.18)]
            editor.linkTextAttributes = [.foregroundColor: ink, .underlineStyle: NSUnderlineStyle.single.rawValue]
            editor.isEditable = isEditable
            if context.coordinator.lastValue != text, !editor.hasMarkedText() {
                let range = editor.selectedRange()
                editor.textStorage?.setAttributedString(HerdrNoteTextStyle.native(text, ink: ink))
                editor.setSelectedRange(NSRange(location: min(range.location, editor.string.utf16.count), length: 0))
                editor.typingAttributes = HerdrNoteTextStyle.attributes([:], ink: ink)
                // Remote edits and AI replacements must not resurrect stale text through Undo.
                editor.undoManager?.removeAllActions()
                context.coordinator.lastValue = text
                DispatchQueue.main.async { [weak controls] in controls?.refresh() }
            }
            if context.coordinator.focusRequest != focusRequest {
                context.coordinator.focusRequest = focusRequest
                DispatchQueue.main.async { [weak editor] in
                    guard let editor, editor.isEditable else { return }
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: NativeEditor
            var lastValue: AttributedString?
            var focusRequest: UUID?
            var isUpdating = false

            init(_ parent: NativeEditor) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let editor = notification.object as? HerdrNoteTextView, let storage = editor.textStorage else { return }
                let value = HerdrNoteTextStyle.rich(storage)
                lastValue = value
                parent.text = value
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard !isUpdating else { return }
                parent.controls.refresh()
            }
        }
    }
}
