import AppKit
import SwiftUI

/// A window-modal, presentation-only edit; the feature's underlying title is untouched.
struct FirstMateConversationPresentationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: FirstMateConversation
    let save: (_ label: String?, _ emoji: String?) async -> String?
    let openEmojiPicker: () -> Void

    @State private var draft: FirstMateConversationPresentationDraft
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, emoji }

    init(conversation: FirstMateConversation,
         save: @escaping (_ label: String?, _ emoji: String?) async -> String?,
         openEmojiPicker: @escaping () -> Void = { NSApp.orderFrontCharacterPalette(nil) }) {
        self.conversation = conversation
        self.save = save
        self.openEmojiPicker = openEmojiPicker
        _draft = State(initialValue: FirstMateConversationPresentationDraft(conversation: conversation))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename or change emoji")
                .herdrFont(size: 17, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)

            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("Title")
                TextField("Conversation name", text: Binding(
                    get: { draft.name },
                    set: { draft.name = String(String.UnicodeScalarView($0.unicodeScalars.prefix(FirstMateConversationPresentationDraft.nameLimit))) }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .name)
                .onSubmit(saveChanges)
                .disabled(isSaving)
                .accessibilityIdentifier("first-mate-presentation-name")
                HStack {
                    Text("Shown in the chat window and First Mate HUD.")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                    Spacer()
                    Text("\(draft.name.unicodeScalars.count)/\(FirstMateConversationPresentationDraft.nameLimit)")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
                Button("Use feature title") { draft.resetName() }
                    .disabled(isSaving || draft.name == conversation.title)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Emoji")
                HStack {
                    Spacer()
                    FirstMateEmojiDisc(emoji: draft.emoji, size: 48)
                    Spacer()
                }
                FirstMateFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(FirstMateDefaultEmoji.palette, id: \.self) { emoji in
                        Button { draft.setEmojiText(emoji) } label: {
                            Text(emoji)
                                .herdrFont(size: 20)
                                .frame(width: 36, height: 36)
                                .background(draft.emoji == emoji ? HerdrTheme.selectedFill : HerdrTheme.inkFill(0.05),
                                            in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.herdrPlain)
                        .accessibilityLabel("Select \(emoji) emoji")
                        .disabled(isSaving)
                    }
                }
                HStack(spacing: 12) {
                    TextField("Emoji", text: Binding(
                        get: { draft.emoji }, set: { draft.setEmojiText($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .herdrFont(size: 22)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .focused($focus, equals: .emoji)
                    .disabled(isSaving)
                    .accessibilityIdentifier("first-mate-presentation-emoji")
                    Button("Choose emoji…") {
                        // Character Viewer inserts at the caret; an existing emoji
                        // must not win normalization over the newly picked one.
                        draft.setEmojiText("")
                        focus = .emoji
                        // SwiftUI installs the field's first responder on the next pass.
                        DispatchQueue.main.async { chooseEmoji() }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("first-mate-presentation-pick-emoji")
                    Button("Use default") { draft.resetEmoji() }
                        .disabled(isSaving)
                }
            }

            if let error {
                Text(error)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.warning)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isSaving)
                Button("Save", action: saveChanges)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !draft.canSave)
                    .accessibilityIdentifier("first-mate-presentation-save")
            }
        }
        .padding(20)
        .frame(width: 460)
        .controlSize(.large)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focus = .name }
    }

    /// Kept internal so a hosting test can exercise the picker action without opening system UI.
    func chooseEmoji() { openEmojiPicker() }

    static func labelForSave(_ label: String?, draftName: String, conversation: FirstMateConversation) -> String? {
        !conversation.isUserNamed && draftName == conversation.title ? nil : label
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
            .foregroundStyle(HerdrTheme.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func saveChanges() {
        guard !isSaving, draft.canSave else { return }
        guard let changes = draft.changes(for: conversation) else { dismiss(); return }
        // A default feature title can exceed the name limit. Editing only
        // its emoji must not silently turn the clipped title into a user label.
        let label = Self.labelForSave(changes.label, draftName: draft.name, conversation: conversation)
        guard label != nil || changes.emoji != nil else { dismiss(); return }
        isSaving = true
        error = nil
        Task {
            error = await save(label, changes.emoji)
            isSaving = false
            if error == nil { dismiss() }
        }
    }
}
