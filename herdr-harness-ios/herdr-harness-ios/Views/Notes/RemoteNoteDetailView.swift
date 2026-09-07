import SwiftUI

struct RemoteNoteDetailView: View {
    @Bindable var store: RemoteNotesStore
    let noteID: String
    let machineName: String
    let save: (RemoteNote, String, AttributedString) async throws -> RemoteNote
    @State private var editingNote: RemoteNote?
    let refresh: () async -> Void

    var body: some View {
        ZStack {
            HerdrBackground()
            if let note = store.note(id: noteID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(note.displayTitle)
                                .font(.title2.weight(.bold))
                                .textSelection(.enabled)
                            Label(machineName, systemImage: "desktopcomputer")
                                .font(.subheadline)
                            Text("Updated \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                            Text("Shared with Mac HUD · \(note.statusLabel)")
                                .font(.caption)
                        }
                        .foregroundStyle(HerdrTheme.crust)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(note.color.fill, in: .rect(cornerRadius: 16))

                        if let error = store.machineErrors[note.machineID] {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(HerdrTheme.warning)
                        }

                        if note.body.isEmpty {
                            Text("This note has no body yet.")
                                .font(.body)
                                .foregroundStyle(HerdrTheme.mist)
                        } else {
                            Text(note.richBody)
                                .font(.body)
                                .foregroundStyle(HerdrTheme.crust)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(18)
                                .background(note.color.fill, in: .rect(cornerRadius: 16))
                                .accessibilityIdentifier("note-full-body")
                        }
                        if let summary = note.aiSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Summary", systemImage: "sparkles")
                                    .font(.headline)
                                Text(summary)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                            .foregroundStyle(HerdrTheme.mist)
                        }
                    }
                    .padding(HerdrTheme.pagePadding)
                }
                .refreshable { await refresh() }
            } else {
                ContentUnavailableView("Note no longer available", systemImage: "note.text", description: Text("This note was removed from its Mac or that Mac is no longer configured."))
            }
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingNote) { note in
            RemoteNoteEditorView(note: note) { title, body in
                store.acceptSavedNote(try await save(note, title, body))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", systemImage: "pencil") { editingNote = store.note(id: noteID) }
                    .disabled(store.note(id: noteID) == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh note", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(store.isRefreshing)
            }
        }
        .accessibilityIdentifier("note-detail")
    }
}
