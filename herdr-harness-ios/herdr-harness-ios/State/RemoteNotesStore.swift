import Foundation
import Observation

@MainActor
@Observable
final class RemoteNotesStore {
    private(set) var notes: [RemoteNote] = []
    private(set) var machineErrors: [String: String] = [:]
    private(set) var lastRefreshed: [String: Date] = [:]
    private(set) var isRefreshing = false
    private var refreshRevision = 0

    typealias Fetch = @MainActor @Sendable (String) async throws -> RemoteNotesResponse

    private struct Result: Sendable {
        let machineID: String
        let response: RemoteNotesResponse?
        let error: String?
    }

    /// The screen owns the visible refresh loop. Every refresh has a generation
    /// so a cancelled request or an older machine configuration cannot overwrite
    /// a newer result. A failed machine keeps its last successful notes.
    func refresh(machineIDs: [String], fetch: @escaping Fetch) async {
        refreshRevision += 1
        let revision = refreshRevision
        isRefreshing = true
        let activeIDs = Set(machineIDs)
        notes.removeAll { !activeIDs.contains($0.machineID) }
        machineErrors = machineErrors.filter { activeIDs.contains($0.key) }
        lastRefreshed = lastRefreshed.filter { activeIDs.contains($0.key) }
        defer { if refreshRevision == revision { isRefreshing = false } }
        await withTaskGroup(of: Result.self) { group in
            for machineID in activeIDs {
                group.addTask {
                    do {
                        let response = try await fetch(machineID)
                        guard response.ok else { throw APIError.invalidResponse }
                        return Result(machineID: machineID, response: response, error: nil)
                    } catch {
                        return Result(machineID: machineID, response: nil, error: Self.message(for: error))
                    }
                }
            }
            for await result in group {
                guard revision == refreshRevision, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                apply(result)
            }
        }
    }

    /// Publish each Mac as soon as it replies. An offline second Mac should
    /// never hold a healthy Mac's notes behind its request timeout.
    private func apply(_ result: Result) {
        if let response = result.response {
            let deletedIDs = Set(response.deletedIDs)
            var seenIDs: Set<UUID> = []
            let fresh = response.notes.filter {
                !deletedIDs.contains($0.rawID) && seenIDs.insert($0.rawID).inserted
            }.map { $0.stamped(machineID: result.machineID) }
            notes.removeAll { $0.machineID == result.machineID }
            notes.append(contentsOf: fresh)
            machineErrors[result.machineID] = nil
            lastRefreshed[result.machineID] = .now
        } else {
            machineErrors[result.machineID] = result.error
        }
        notes.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    func acceptSavedNote(_ note: RemoteNote) {
        // Invalidate any fetch that began before this write completed.
        refreshRevision += 1
        isRefreshing = false
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        notes.sort { $0.updatedAt > $1.updatedAt }
        machineErrors[note.machineID] = nil
    }

    func reset() {
        refreshRevision += 1
        notes = []
        machineErrors = [:]
        lastRefreshed = [:]
        isRefreshing = false
    }

    func visibleNotes(machineID: String, search: String) -> [RemoteNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            (machineID.isEmpty || note.machineID == machineID)
                && (query.isEmpty || note.displayTitle.localizedStandardContains(query)
                    || note.body.localizedStandardContains(query))
        }
    }

    func note(id: String) -> RemoteNote? { notes.first { $0.id == id } }

    nonisolated private static func message(for error: any Error) -> String {
        if case let APIError.server(status, _) = error {
            if status == 404 { return "This Mac needs the Herdr notes update." }
            if status == 401 || status == 403 { return "Check this Mac’s connection credentials in Settings." }
        }
        if case APIError.noActiveConnection = error { return "This Mac is offline. Reconnect to refresh its notes." }
        if HerdrCancellation.isCancellation(error) { return "Refresh paused. Pull down to try again." }
        let code = (error as NSError).code
        if (error as NSError).domain == NSURLErrorDomain {
            if code == NSURLErrorTimedOut { return "This Mac took too long to respond. Pull down to retry." }
            return "Couldn’t reach this Mac. Showing any notes already loaded."
        }
        return "Couldn’t refresh notes. Pull down to retry."
    }
}
