import SwiftUI

struct RemoteNoteEditorView: View {
    let note: RemoteNote
    let save: (String, AttributedString) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: AttributedString
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false

    init(note: RemoteNote, save: @escaping (String, AttributedString) async throws -> Void) {
        self.note = note
        self.save = save
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.richBody)
    }

    private var hasChanges: Bool { title != note.title || bodyText != note.richBody }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Untitled note", text: $title)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("note-editor-title")
                    .padding(.top, 8)
                RemoteNoteRichEditor(text: $bodyText, isEditable: !isSaving)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(Color(red: 0.5059, green: 0.1765, blue: 0.2471))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .foregroundStyle(HerdrTheme.crust)
            .background(note.color.fill)
            .toolbarBackground(note.color.fill, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .tint(HerdrTheme.crust)
            .disabled(isSaving)
            .navigationTitle("Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await saveChanges() } }
                        .disabled(isSaving || !hasChanges)
                }
            }
            .confirmationDialog("Discard your edits?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard edits", role: .destructive) { dismiss() }
            }
        }
        .environment(\.colorScheme, .light)
        .interactiveDismissDisabled(hasChanges || isSaving)
    }

    private func saveChanges() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await save(title, bodyText)
            dismiss()
        } catch APIError.server(status: 409, message: _) {
            errorMessage = "This note changed on your Mac or was deleted. Your draft is still here. Copy any edits you want to keep, then cancel and refresh the note before editing again."
        } catch {
            errorMessage = "Couldn’t save your note. Your draft is still here. \(error.localizedDescription)"
        }
    }
}
