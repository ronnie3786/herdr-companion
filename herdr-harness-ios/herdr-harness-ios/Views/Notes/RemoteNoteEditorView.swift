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
            Form {
                Section("Title") {
                    TextField("Untitled note", text: $title)
                }
                Section("Note") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 240)
                        .accessibilityLabel("Note body")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
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
