import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Notes sync")
struct HerdrNotesSyncTests {
    private let local = HerdrMachine(id: "local", name: "This Mac", urlString: "http://localhost:9092")

    @Test("Only an unambiguous local endpoint can automatically own notes")
    func localOwnership() {
        let remote = HerdrMachine(id: "remote", name: "Remote", urlString: "https://other.example:8463")
        #expect(HerdrNotesSource.localMachine(in: [remote, local], hostNames: [], addresses: []) == local)
        #expect(HerdrNotesSource.localMachine(in: [remote], hostNames: ["this-mac"], addresses: []) == nil)
        let second = HerdrMachine(id: "second", name: "Second", urlString: "http://127.0.0.1:9093")
        #expect(HerdrNotesSource.localMachine(in: [local, second], hostNames: [], addresses: []) == nil)
        let source = HerdrNotesSource(machine: local)
        #expect(source.matches(local))
        #expect(!source.matches(HerdrMachine(id: local.id, name: local.name, urlString: remote.urlString)))
    }

    @Test("Six legacy notes import once, retain UUIDs, and preserve original bytes")
    @MainActor func migrationAndBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hud-notes.json")
        let original = (0..<6).map { HerdrNote(title: "Note \($0)", body: "Body \($0)") }
        try HerdrNotesSnapshot(notes: original).save(to: url)
        let bytes = try Data(contentsOf: url)
        let state = makeState(url: url)
        await state.waitForPersistenceRestoreForTesting()
        state.chooseSyncSource(local)
        let backend = NotesTestBackend()
        await state.syncNotes(using: backend)
        await state.syncNotes(using: backend)
        #expect(await backend.importCount == 1)
        #expect(Set(await backend.collection.notes.map { $0.note.id }) == Set(original.map(\.id)))
        #expect(state.notes == original)
        #expect(state.syncPendingCount == 0)
        #expect(try Data(contentsOf: directory.appendingPathComponent("hud-notes.pre-sync-backup.json")) == bytes)
        let persisted = try #require(HerdrNotesSnapshot.load(from: url))
        #expect(persisted.sync?.source == HerdrNotesSource(machine: local))
        #expect(persisted.sync?.imported == true)
    }

    @Test("Offline edits survive restart and cannot follow another selected machine")
    @MainActor func offlineRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hud-notes.json")
        let state = makeState(url: url)
        await state.waitForPersistenceRestoreForTesting()
        state.chooseSyncSource(local)
        let id = state.createNote()
        state.updateBody("Offline draft", for: id)
        let backend = NotesTestBackend()
        await backend.setOffline(true)
        await state.syncNotes(using: backend)
        #expect(state.syncError != nil)
        let restored = makeState(url: url)
        await restored.waitForPersistenceRestoreForTesting()
        restored.chooseSyncSource(HerdrMachine(id: "another", name: "Another", urlString: "https://another.example"))
        #expect(restored.syncSource?.machineID == "local")
        #expect(restored.note(id: id)?.body == "Offline draft")
        #expect(restored.syncPendingCount == 1)
        await backend.setOffline(false)
        await restored.syncNotes(using: backend)
        #expect(restored.syncPendingCount == 0)
        #expect(await backend.collection.notes.first?.note.body == "Offline draft")
    }

    @Test("Concurrent CLI edits stay intact and local drafts can be recovered separately")
    @MainActor func concurrentEdit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = makeState(url: directory.appendingPathComponent("hud-notes.json"))
        await state.waitForPersistenceRestoreForTesting()
        state.chooseSyncSource(local)
        let id = state.createNote()
        state.updateBody("Original", for: id)
        let backend = NotesTestBackend()
        await state.syncNotes(using: backend)
        state.updateBody("Mac draft", for: id)
        try await backend.edit(id: id, body: "CLI edit")
        await state.syncNotes(using: backend)
        #expect(state.note(id: id)?.body == "Mac draft")
        #expect(state.syncConflict(for: id)?.remote?.note.body == "CLI edit")
        #expect(await backend.updateCount == 0)
        state.resolveSyncConflict(id, keepLocalCopy: true)
        await state.syncNotes(using: backend)
        #expect(state.note(id: id)?.body == "CLI edit")
        #expect(state.notes.contains { $0.id != id && $0.body == "Mac draft" })
        #expect(await backend.collection.notes.count == 2)
    }

    @Test("Acknowledging a request preserves edits made while it was in flight")
    func editDuringRequest() {
        var note = HerdrNote(body: "First")
        let sent = HerdrNotesSyncJournal.Mutation(id: note.id, note: note, expectedRevision: 1)
        var journal = HerdrNotesSyncJournal()
        journal.pending = [sent]
        note.richBody = AttributedString("Second")
        journal.pending[0].note = note
        var visible = [note]
        journal.acknowledge(.init(note: sent.note!, revision: 2), sent: sent, notes: &visible)
        #expect(visible[0].body == "Second")
        #expect(journal.pending[0].expectedRevision == 2)
    }

    @Test("A lost response is acknowledged by the next fetch")
    func lostResponse() {
        let note = HerdrNote(body: "Uploaded")
        var journal = HerdrNotesSyncJournal()
        journal.pending = [.init(id: note.id, note: note, expectedRevision: 1)]
        var visible = [note]
        journal.merge(.init(revision: 2, notes: [.init(note: note, revision: 2)], deletedIDs: []), notes: &visible)
        #expect(journal.pending.isEmpty)
        #expect(journal.conflicts.isEmpty)
        #expect(journal.base.first?.revision == 2)
    }

    @Test("A conflicting deletion stays reachable and tombstones never resurrect old IDs")
    func deleteConflictAndTombstone() {
        let original = HerdrNote(body: "Original")
        var newer = original
        newer.richBody = AttributedString("Changed remotely")
        var journal = HerdrNotesSyncJournal()
        journal.base = [.init(note: original, revision: 1)]
        journal.pending = [.init(id: original.id, note: nil, expectedRevision: 1)]
        var visible: [HerdrNote] = []
        journal.merge(.init(revision: 2, notes: [.init(note: newer, revision: 2)], deletedIDs: []), notes: &visible)
        #expect(visible.first?.body == "Changed remotely")
        #expect(journal.conflicts.count == 1)
        journal.resolveConflict(id: original.id, keepCopy: false, notes: &visible)
        journal.captureChanges(from: visible, to: [original])
        visible = [original]
        journal.merge(.init(revision: 3, notes: [], deletedIDs: [original.id]), notes: &visible)
        #expect(journal.conflicts.first?.remote == nil)
        #expect(visible.first?.body == "Original")
        journal.resolveConflict(id: original.id, keepCopy: true, notes: &visible)
        #expect(visible.count == 1)
        #expect(visible[0].id != original.id)
    }

    @Test("Existing import IDs cannot be overwritten with different local contents")
    func importConflict() {
        let note = HerdrNote(body: "Local")
        var remote = note
        remote.richBody = AttributedString("Already on source")
        var journal = HerdrNotesSyncJournal()
        journal.captureChanges(from: [], to: [note])
        var visible = [note]
        journal.finishImport(.init(revision: 8, notes: [.init(note: remote, revision: 8)], deletedIDs: []), sent: [note], notes: &visible)
        #expect(journal.imported)
        #expect(journal.conflicts.count == 1)
        #expect(visible[0].body == "Local")
    }

    @Test("Unknown rich encodings fall back to the portable body")
    func unknownRichText() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Future note","body":"Readable","richBody":{"future":true},"createdAt":0,"updatedAt":0,
        "previousVersion":{"title":"Before","body":"Original","richBody":{"unknown":1},"replacedAt":0}}
        """
        let note = try JSONDecoder().decode(HerdrNote.self, from: Data(json.utf8))
        #expect(note.body == "Readable")
        #expect(note.previousVersion?.body == "Original")
    }

    @Test("Conditional updates encode cleared optionals and omit immutable metadata")
    func updatePayload() throws {
        let payload = HerdrNoteUpdateRequest(expectedRevision: 7, changes: .init(note: HerdrNote(body: "Updated")))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let changes = try #require(json["changes"] as? [String: Any])
        #expect(json["expectedRevision"] as? Int == 7)
        #expect(changes["previousVersion"] is NSNull)
        #expect(changes["aiSummary"] is NSNull)
        #expect(changes["lastCleanedAt"] is NSNull)
        #expect(changes["id"] == nil)
        #expect(changes["createdAt"] == nil)
        #expect(changes["updatedAt"] == nil)
    }

    @Test("Local recovery copies are not trimmed when the collection reaches its limit")
    func recoveryBeyondLimit() {
        let notes = (0..<101).map { HerdrNote(title: "\($0)") }
        var journal = HerdrNotesSyncJournal()
        journal.captureChanges(from: [], to: notes)
        #expect(HerdrNotesSnapshot(notes: notes, sync: journal).notes.count == 101)
    }

    @Test("Final termination save cannot be replaced by an older debounced write")
    func terminationSaveWins() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hud-notes.json")
        var note = HerdrNote(body: "Earlier")
        var journal = HerdrNotesSyncJournal()
        journal.generation = 1
        let store = HerdrNotesStore(fileURL: url)
        await store.scheduleSave(.init(notes: [note], sync: journal), delay: .seconds(60))
        note.richBody = AttributedString("Final offline edit")
        journal.generation = 2
        try HerdrNotesStore.savePreservingOriginal(.init(notes: [note], sync: journal), to: url)
        await store.flush()
        #expect(HerdrNotesSnapshot.load(from: url)?.notes.first?.body == "Final offline edit")
    }

    @Test("Idle polling does not rewrite a snapshot just to advance its generation")
    func idleSnapshotDoesNotWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hud-notes.json")
        let note = HerdrNote(body: "Stable")
        var journal = HerdrNotesSyncJournal()
        journal.generation = 1
        try HerdrNotesStore.savePreservingOriginal(.init(notes: [note], sync: journal), to: url)
        let first = try Data(contentsOf: url)
        journal.generation = 2
        try HerdrNotesStore.savePreservingOriginal(.init(notes: [note], sync: journal), to: url)
        #expect(try Data(contentsOf: url) == first)
    }

    @Test("AI cannot replace a note edited while cleanup or planning was running", arguments: [false, true])
    @MainActor func aiKeepsNewerInput(planning: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "NotesAIRace-\(UUID().uuidString)")!
        let model = HerdrAppModel(arguments: ["Tests", "-HerdrDemoMode"], userDefaults: defaults)
        let ai = FakeNoteAIRunner()
        ai.mode = .succeed(planning ? #"{"summary":"AI","actions":[{"title":"Do","prompt":"Do it"}]}"# : "AI rewrite")
        let state = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults),
            promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: directory.appendingPathComponent("hud-notes.json"), aiRunner: ai)
        await state.waitForPersistenceRestoreForTesting()
        let id = state.createNote()
        state.updateBody("Original", for: id)
        ai.onRun = { state.updateBody("Newer input", for: id) }
        if planning { await state.planActions(id, model: model) }
        else { await state.cleanUp(id, model: model) }
        ai.onRun = nil
        #expect(state.note(id: id)?.body == "Newer input")
        #expect(state.note(id: id)?.actions.isEmpty == true)
        #expect(state.noteErrors[id] == "Note changed while AI was working. Try again.")
    }

    @Test("CLI changes during AI keep their revision and become a recoverable conflict", arguments: [false, true])
    @MainActor func cliEditDuringAI(planning: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "NotesCLIRace-\(UUID().uuidString)")!
        let model = HerdrAppModel(arguments: ["Tests", "-HerdrDemoMode"], userDefaults: defaults)
        let ai = FakeNoteAIRunner()
        ai.mode = .succeed(planning ? #"{"summary":"AI","actions":[{"title":"Do","prompt":"Do it"}]}"# : "AI rewrite")
        let state = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults),
            promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: directory.appendingPathComponent("hud-notes.json"), aiRunner: ai)
        await state.waitForPersistenceRestoreForTesting()
        state.chooseSyncSource(local)
        let id = state.createNote()
        state.updateBody("Original", for: id)
        let backend = NotesTestBackend()
        await state.syncNotes(using: backend)
        ai.onRun = {
            try? await backend.edit(id: id, body: "CLI changed this")
            await state.syncNotes(using: backend)
        }
        if planning { await state.planActions(id, model: model) }
        else { await state.cleanUp(id, model: model) }
        ai.onRun = nil
        await state.syncNotes(using: backend)
        #expect(state.syncConflict(for: id)?.remote?.note.body == "CLI changed this")
        #expect(await backend.collection.notes.first?.note.body == "CLI changed this")
        #expect(await backend.updateCount == 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HerdrNotesSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor private func makeState(url: URL) -> HerdrHudNotesState {
        let defaults = UserDefaults(suiteName: "HerdrNotesSyncTests-\(UUID().uuidString)")!
        return HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults),
            promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: url, saveDelay: .seconds(60))
    }
}

private actor NotesTestBackend: HerdrNotesClient {
    var collection = HerdrNotesCollection(revision: 0, notes: [], deletedIDs: [])
    var importCount = 0
    var updateCount = 0
    private var offline = false
    func setOffline(_ value: Bool) { offline = value }
    func fetchNotes() throws -> HerdrNotesCollection {
        if offline { throw URLError(.notConnectedToInternet) }
        return collection
    }
    func importNotes(_ notes: [HerdrNote]) throws -> HerdrNotesCollection {
        if offline { throw URLError(.notConnectedToInternet) }
        importCount += 1
        for note in notes { _ = try createNote(note) }
        return collection
    }
    func createNote(_ note: HerdrNote) throws -> HerdrSyncedNote {
        if offline { throw URLError(.notConnectedToInternet) }
        if let existing = collection.notes.first(where: { $0.note.id == note.id }) { return existing }
        if collection.deletedIDs.contains(note.id) { throw HerdrNotesConflictError(currentNote: nil) }
        let synced = HerdrSyncedNote(note: note, revision: collection.revision + 1)
        collection = .init(revision: synced.revision, notes: collection.notes + [synced], deletedIDs: collection.deletedIDs)
        return synced
    }
    func updateNote(_ note: HerdrNote, expectedRevision: Int) throws -> HerdrSyncedNote {
        if offline { throw URLError(.notConnectedToInternet) }
        let existing = collection.notes.first { $0.note.id == note.id }
        guard existing?.revision == expectedRevision else { throw HerdrNotesConflictError(currentNote: existing) }
        updateCount += 1
        let synced = HerdrSyncedNote(note: note, revision: collection.revision + 1)
        collection = .init(revision: synced.revision, notes: collection.notes.filter { $0.note.id != note.id } + [synced], deletedIDs: collection.deletedIDs)
        return synced
    }
    func deleteNote(id: UUID, expectedRevision: Int) throws {
        let existing = collection.notes.first { $0.note.id == id }
        guard existing?.revision == expectedRevision else { throw HerdrNotesConflictError(currentNote: existing) }
        collection = .init(revision: collection.revision + 1, notes: collection.notes.filter { $0.note.id != id }, deletedIDs: collection.deletedIDs + [id])
    }
    func edit(id: UUID, body: String) throws {
        var existing = try #require(collection.notes.first { $0.note.id == id })
        existing.note.richBody = AttributedString(body)
        _ = try updateNote(existing.note, expectedRevision: existing.revision)
        updateCount = 0
    }
}
