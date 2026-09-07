import Foundation
import Synchronization

struct HerdrNotesSnapshot: Codable, Sendable {
    static let currentVersion = 1
    static let maximumNoteCount = 100
    static let maximumBodyLength = 20_000

    let version: Int
    let notes: [HerdrNote]
    let sync: HerdrNotesSyncJournal?

    init(version: Int = HerdrNotesSnapshot.currentVersion, notes: [HerdrNote], sync: HerdrNotesSyncJournal? = nil) {
        self.version = version
        self.sync = sync
        var trimmed = notes
        // Synced snapshots may temporarily contain a recovery copy beyond the
        // server limit. Never discard an offline draft or its conflict copy.
        if sync == nil, trimmed.count > Self.maximumNoteCount {
            let idsToKeep = Set(trimmed.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maximumNoteCount).map(\.id))
            trimmed = trimmed.filter { idsToKeep.contains($0.id) }
        }
        self.notes = trimmed.map { note in
            guard note.richBody.characters.count > Self.maximumBodyLength else { return note }
            var copy = note
            copy.richBody = HerdrNoteRichText.truncated(note.richBody, to: Self.maximumBodyLength)
            return copy
        }
    }

    static func load(from fileURL: URL) -> HerdrNotesSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == Self.currentVersion
        else { return nil }
        return snapshot
    }

    func save(to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: fileURL, options: .atomic)
    }
}

actor HerdrNotesStore {
    // The app-termination callback is synchronous. It shares this gate with
    // actor writes so a delayed flush cannot race or overwrite its final save.
    private static let savedSnapshots = Mutex<[String: HerdrNotesSnapshot]>([:])
    let fileURL: URL
    private var pendingSnapshot: HerdrNotesSnapshot?
    private var flushTask: Task<Void, Never>?
    private var latestGeneration = -1

    init(fileURL: URL = HerdrNotesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "herdr-harness-mac"
        return applicationSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("hud-notes.json", isDirectory: false)
    }

    func load() -> HerdrNotesSnapshot? {
        Self.savedSnapshots.withLock { saved in
            saved[fileURL.path] ?? HerdrNotesSnapshot.load(from: fileURL)
        }
    }

    func scheduleSave(_ snapshot: HerdrNotesSnapshot, delay: Duration = .milliseconds(500)) {
        guard accept(snapshot) else { return }
        pendingSnapshot = snapshot
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        try? savePreservingOriginal(snapshot)
    }

    func saveImmediately(_ snapshot: HerdrNotesSnapshot) throws {
        guard accept(snapshot) else {
            if let pendingSnapshot { try Self.savePreservingOriginal(pendingSnapshot, to: fileURL) }
            return
        }
        flushTask?.cancel()
        flushTask = nil
        pendingSnapshot = nil
        try savePreservingOriginal(snapshot)
    }

    private func accept(_ snapshot: HerdrNotesSnapshot) -> Bool {
        guard let generation = snapshot.sync?.generation else { return true }
        guard generation >= latestGeneration else { return false }
        latestGeneration = generation
        return true
    }

    private func savePreservingOriginal(_ snapshot: HerdrNotesSnapshot) throws {
        try Self.savePreservingOriginal(snapshot, to: fileURL)
    }

    static func savePreservingOriginal(_ snapshot: HerdrNotesSnapshot, to fileURL: URL) throws {
        try savedSnapshots.withLock { saved in
            let prior = saved[fileURL.path] ?? HerdrNotesSnapshot.load(from: fileURL)
            if let generation = snapshot.sync?.generation, let previous = prior?.sync?.generation,
               generation < previous { return }
            if let prior {
                var comparableJournal = prior.sync
                comparableJournal?.generation = snapshot.sync?.generation ?? 0
                if prior.notes == snapshot.notes, comparableJournal == snapshot.sync {
                    saved[fileURL.path] = snapshot
                    return
                }
            }
            if snapshot.sync != nil, FileManager.default.fileExists(atPath: fileURL.path), prior?.sync == nil {
                let backup = fileURL.deletingPathExtension().appendingPathExtension("pre-sync-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: fileURL, to: backup)
                }
            }
            try snapshot.save(to: fileURL)
            saved[fileURL.path] = snapshot
        }
    }

    #if DEBUG
    func waitForPendingFlushForTesting() async { await flushTask?.value }
    #endif

    func remove() {
        pendingSnapshot = nil
        flushTask?.cancel()
        flushTask = nil
        Self.savedSnapshots.withLock { saved in
            saved[fileURL.path] = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
