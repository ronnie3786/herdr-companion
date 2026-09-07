import Foundation

protocol HerdrNotesClient: Sendable {
    func fetchNotes() async throws -> HerdrNotesCollection
    func importNotes(_ notes: [HerdrNote]) async throws -> HerdrNotesCollection
    func createNote(_ note: HerdrNote) async throws -> HerdrSyncedNote
    func updateNote(_ note: HerdrNote, expectedRevision: Int) async throws -> HerdrSyncedNote
    func deleteNote(id: UUID, expectedRevision: Int) async throws
}

/// Notes belong to one backend, independently of the machine selected for chats.
struct HerdrNotesSource: Codable, Equatable, Sendable {
    let machineID: String
    let endpoint: String

    init(machine: HerdrMachine) {
        machineID = machine.id
        endpoint = Self.normalizedEndpoint(machine.urlString)
    }

    func matches(_ machine: HerdrMachine) -> Bool {
        machine.id == machineID && Self.normalizedEndpoint(machine.urlString) == endpoint
    }

    static func normalizedEndpoint(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return raw }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? raw
    }

    static func localMachine(in machines: [HerdrMachine], hostNames: [String], addresses: [String]) -> HerdrMachine? {
        let loopback = Set(["localhost", "127.0.0.1", "::1"])
        let hosts = Set((hostNames + addresses).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) })
        func host(_ machine: HerdrMachine) -> String {
            (URLComponents(string: machine.urlString)?.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        let local = machines.filter { loopback.contains(host($0)) }
        if local.count == 1 { return local[0] }
        guard local.isEmpty else { return nil }
        let matching = machines.filter { hosts.contains(host($0)) }
        return matching.count == 1 ? matching[0] : nil
    }
}

struct HerdrSyncedNote: Codable, Equatable, Sendable {
    var note: HerdrNote
    let revision: Int

    init(note: HerdrNote, revision: Int) { self.note = note; self.revision = revision }
    private enum CodingKeys: String, CodingKey { case revision }
    init(from decoder: Decoder) throws {
        note = try HerdrNote(from: decoder)
        revision = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .revision)
    }
    func encode(to encoder: Encoder) throws {
        try note.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
    }
}

struct HerdrNotesCollection: Decodable, Sendable {
    let revision: Int
    let notes: [HerdrSyncedNote]
    let deletedIDs: [UUID]
}

struct HerdrNoteMutationResponse: Decodable, Sendable { let note: HerdrSyncedNote }
struct HerdrNoteDeleteResponse: Decodable, Sendable { let deleted: Bool }
struct HerdrNotesConflictResponse: Decodable, Sendable {
    struct Detail: Decodable, Sendable { let code: String }
    let error: Detail
    let currentNote: HerdrSyncedNote?
}
struct HerdrNotesConflictError: Error, Sendable { let currentNote: HerdrSyncedNote? }
struct HerdrNoteCreateRequest: Encodable, Sendable { let note: HerdrNote }
struct HerdrNotesImportRequest: Encodable, Sendable { let notes: [HerdrNote] }
struct HerdrNoteDeleteRequest: Encodable, Sendable { let expectedRevision: Int }
struct HerdrNoteUpdateRequest: Encodable, Sendable {
    let expectedRevision: Int
    let changes: Changes
    struct Changes: Encodable, Sendable {
        let note: HerdrNote
        private enum CodingKeys: String, CodingKey {
            case title, body, richBody, color, previousVersion, aiSummary, actions, links, lastCleanedAt
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(note.title, forKey: .title)
            try HerdrNoteRichText.encode(note.richBody, into: &container, richKey: .richBody, plainKey: .body)
            try container.encode(note.color, forKey: .color)
            try container.encode(note.previousVersion, forKey: .previousVersion)
            try container.encode(note.aiSummary, forKey: .aiSummary)
            try container.encode(note.actions, forKey: .actions)
            try container.encode(note.links, forKey: .links)
            try container.encode(note.lastCleanedAt, forKey: .lastCleanedAt)
        }
    }
}

/// The journal and visible notes are saved together, so an offline edit cannot
/// be restored without the revision against which it must be submitted.
struct HerdrNotesSyncJournal: Codable, Equatable, Sendable {
    struct Mutation: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var note: HerdrNote?
        var expectedRevision: Int?
    }
    struct Conflict: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var remote: HerdrSyncedNote?
    }
    var source: HerdrNotesSource?
    var imported = false
    var generation = 0
    var base: [HerdrSyncedNote] = []
    var pending: [Mutation] = []
    var conflicts: [Conflict] = []

    mutating func captureChanges(from previous: [HerdrNote], to current: [HerdrNote]) {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
            if let index = pending.firstIndex(where: { $0.id == id }) {
                pending[index].note = new[id]
            } else {
                pending.append(Mutation(id: id, note: new[id], expectedRevision: base.first { $0.note.id == id }?.revision))
            }
        }
    }

    static func sameContent(_ lhs: HerdrNote, _ rhs: HerdrNote) -> Bool {
        var comparable = lhs
        comparable.updatedAt = rhs.updatedAt
        return comparable == rhs
    }

    mutating func acknowledge(_ remote: HerdrSyncedNote, sent: Mutation, notes: inout [HerdrNote]) {
        setBase(remote)
        conflicts.removeAll { $0.id == sent.id }
        guard let index = pending.firstIndex(where: { $0.id == sent.id }) else { return }
        if pending[index] == sent {
            pending.remove(at: index)
            replace(remote.note, in: &notes)
        } else {
            // The user edited or deleted this note while its request was in flight.
            pending[index].expectedRevision = remote.revision
        }
    }

    mutating func acknowledgeDeletion(_ sent: Mutation, notes: inout [HerdrNote]) {
        base.removeAll { $0.note.id == sent.id }
        conflicts.removeAll { $0.id == sent.id }
        guard let pendingIndex = pending.firstIndex(where: { $0.id == sent.id }) else { return }
        if pending[pendingIndex] == sent {
            pending.remove(at: pendingIndex)
            notes.removeAll { $0.id == sent.id }
        } else {
            recordConflict(id: sent.id, remote: nil, notes: &notes)
        }
    }

    mutating func recordConflict(id: UUID, remote: HerdrSyncedNote?, notes: inout [HerdrNote]) {
        conflicts.removeAll { $0.id == id }
        conflicts.append(Conflict(id: id, remote: remote))
        // A conflicting deletion must remain reachable in the note UI.
        if !notes.contains(where: { $0.id == id }), let recovery = remote?.note ?? base.first(where: { $0.note.id == id })?.note {
            notes.insert(recovery, at: 0)
        }
    }

    mutating func merge(_ collection: HerdrNotesCollection, notes: inout [HerdrNote]) {
        let deleted = Set(collection.deletedIDs)
        for remote in collection.notes {
            let id = remote.note.id
            if let mutation = pending.first(where: { $0.id == id }) {
                if let draft = mutation.note, Self.sameContent(draft, remote.note) {
                    acknowledge(remote, sent: mutation, notes: &notes)
                } else if mutation.expectedRevision != remote.revision {
                    recordConflict(id: id, remote: remote, notes: &notes)
                }
            } else {
                setBase(remote)
                replace(remote.note, in: &notes)
            }
        }
        for id in deleted {
            if let mutation = pending.first(where: { $0.id == id }) {
                if mutation.note == nil { acknowledgeDeletion(mutation, notes: &notes) }
                else { recordConflict(id: id, remote: nil, notes: &notes) }
            } else {
                base.removeAll { $0.note.id == id }
                notes.removeAll { $0.id == id }
            }
        }
        let remoteIDs = Set(collection.notes.map { $0.note.id }).union(deleted)
        // A backend reset must not silently destroy an acknowledged note.
        for prior in base where !remoteIDs.contains(prior.note.id) {
            let id = prior.note.id
            if !pending.contains(where: { $0.id == id }) {
                pending.append(Mutation(id: id, note: notes.first { $0.id == id } ?? prior.note, expectedRevision: prior.revision))
            }
            recordConflict(id: id, remote: nil, notes: &notes)
        }
        // A local create deleted before it was submitted requires no server write.
        pending.removeAll { $0.note == nil && $0.expectedRevision == nil && !remoteIDs.contains($0.id) }
    }

    mutating func finishImport(_ collection: HerdrNotesCollection, sent: [HerdrNote], notes: inout [HerdrNote]) {
        for remote in collection.notes {
            guard let original = sent.first(where: { $0.id == remote.note.id }), Self.sameContent(original, remote.note) else { continue }
            acknowledge(remote, sent: Mutation(id: original.id, note: original, expectedRevision: nil), notes: &notes)
        }
        imported = true
        merge(collection, notes: &notes)
    }

    mutating func resolveConflict(id: UUID, keepCopy: Bool, notes: inout [HerdrNote]) {
        guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
        let local = pending.first(where: { $0.id == id })?.note
        pending.removeAll { $0.id == id }
        conflicts.removeAll { $0.id == id }
        base.removeAll { $0.note.id == id }
        notes.removeAll { $0.id == id }
        if let remote = conflict.remote {
            setBase(remote)
            notes.insert(remote.note, at: 0)
        }
        if keepCopy, let local {
            var copy = HerdrNote(title: local.title + " (local copy)", color: local.color, previousVersion: local.previousVersion,
                                 aiSummary: local.aiSummary, actions: local.actions, links: local.links, lastCleanedAt: local.lastCleanedAt)
            copy.richBody = local.richBody
            notes.insert(copy, at: 0)
            pending.append(Mutation(id: copy.id, note: copy, expectedRevision: nil))
        }
    }

    private mutating func setBase(_ remote: HerdrSyncedNote) {
        base.removeAll { $0.note.id == remote.note.id }
        base.append(remote)
    }
    private func replace(_ note: HerdrNote, in notes: inout [HerdrNote]) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
        else { notes.insert(note, at: 0) }
    }
}
