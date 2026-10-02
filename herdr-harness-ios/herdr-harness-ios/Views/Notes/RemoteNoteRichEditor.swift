import SwiftUI
import UIKit

struct RemoteNoteRichEditor: View {
    @Binding var text: AttributedString
    let isEditable: Bool
    @State private var controls = Controls()
    @State private var showsHelp = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(HerdrNoteTextStyle.Format.allCases, id: \.self) { format in
                    Button { controls.editor?.toggle(format) } label: {
                        Image(systemName: format.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(HerdrTheme.crust.opacity(controls.active.contains(format) ? 0.10 : 0), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(format.label)
                    .accessibilityAddTraits(controls.active.contains(format) ? .isSelected : [])
                    .accessibilityIdentifier("note-format-\(format.rawValue)")
                }
                Spacer(minLength: 0)
                Button("Formatting help", systemImage: "questionmark.circle") { showsHelp.toggle() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Format as you write").font(.headline)
                            Text("**bold**\n*italic* or _italic_\n~~strikethrough~~")
                                .font(.system(.body, design: .monospaced))
                            Text("Use the underline button or ⌘U. External keyboards also support ⌘B and ⌘I.")
                                .font(.callout)
                        }
                        .padding(20)
                        .presentationCompactAdaptation(.popover)
                    }
            }
            .disabled(!isEditable)
            NativeEditor(text: $text, isEditable: isEditable, controls: controls, dynamicTypeSize: dynamicTypeSize)
                .overlay(alignment: .topLeading) {
                    if text.characters.isEmpty {
                        Text("Jot something down…")
                            .font(.body)
                            .foregroundStyle(HerdrTheme.crust.opacity(0.5))
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .foregroundStyle(HerdrTheme.crust)
    }

    @MainActor @Observable
    final class Controls {
        weak var editor: RemoteNoteTextView?
        var active: Set<HerdrNoteTextStyle.Format> = []
        func refresh() {
            guard let editor else { return }
            active = Set(HerdrNoteTextStyle.Format.allCases.filter(editor.isActive))
        }
    }

    private struct NativeEditor: UIViewRepresentable {
        @Binding var text: AttributedString
        let isEditable: Bool
        let controls: Controls
        let dynamicTypeSize: DynamicTypeSize

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> RemoteNoteTextView {
            let editor = RemoteNoteTextView()
            editor.backgroundColor = .clear
            editor.overrideUserInterfaceStyle = .light
            editor.ink = UIColor(HerdrTheme.crust)
            editor.tintColor = editor.ink
            editor.isScrollEnabled = true
            editor.keyboardDismissMode = .interactive
            editor.allowsEditingTextAttributes = true
            editor.textFormattingConfiguration = .init(groups: [
                .init(components: [.init(componentKey: .fontAttributes, preferredSize: .mini)])
            ])
            editor.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
            editor.textContainer.lineFragmentPadding = 0
            editor.accessibilityLabel = "Note body"
            editor.accessibilityIdentifier = "note-editor-body"
            editor.delegate = context.coordinator
            editor.onTextChange = { [weak coordinator = context.coordinator, weak editor] in
                if let editor { coordinator?.changed(editor) }
            }
            editor.onSelectionChange = { [weak controls] in controls?.refresh() }
            controls.editor = editor
            return editor
        }

        func updateUIView(_ editor: RemoteNoteTextView, context: Context) {
            let coordinator = context.coordinator
            coordinator.parent = self
            coordinator.isUpdating = true
            defer { coordinator.isUpdating = false }
            editor.isEditable = isEditable
            if coordinator.lastValue != text, editor.markedTextRange == nil {
                let location = min(editor.selectedRange.location, String(text.characters).utf16.count)
                editor.attributedText = HerdrNoteTextStyle.native(text, ink: editor.ink)
                editor.selectedRange = NSRange(location: location, length: 0)
                editor.typingAttributes = HerdrNoteTextStyle.attributes([:], ink: editor.ink)
                editor.undoManager?.removeAllActions()
                coordinator.lastValue = text
                DispatchQueue.main.async { [weak controls] in controls?.refresh() }
            } else if coordinator.lastSize != dynamicTypeSize, editor.markedTextRange == nil {
                editor.normalizeTypography()
            }
            coordinator.lastSize = dynamicTypeSize
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: NativeEditor
            var lastValue: AttributedString?
            var lastSize: DynamicTypeSize?
            var isUpdating = false
            init(_ parent: NativeEditor) { self.parent = parent }

            func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                guard let editor = textView as? RemoteNoteTextView else { return true }
                return !editor.convertMarkdown(in: range, replacement: text)
            }

            func textViewDidChange(_ textView: UITextView) {
                guard let editor = textView as? RemoteNoteTextView else { return }
                changed(editor)
            }

            func changed(_ editor: RemoteNoteTextView) {
                guard !isUpdating, editor.markedTextRange == nil else { return }
                editor.normalizeTypography()
                let value = HerdrNoteTextStyle.rich(editor.textStorage)
                lastValue = value
                parent.text = value
                parent.controls.refresh()
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard !isUpdating else { return }
                parent.controls.refresh()
            }
        }
    }
}
