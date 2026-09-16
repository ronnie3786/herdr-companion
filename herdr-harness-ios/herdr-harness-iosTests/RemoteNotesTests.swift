import Foundation
import Observation
import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Shared note decoding")
struct RemoteNoteTests {
    @Test("Dates use the Mac reference epoch and IDs remain machine scoped")
    func compatibleDatesAndIdentity() throws {
        let note = try NotesTestPayload.note(title: "A note", timestamp: 1_000)
        #expect(note.updatedAt == Date(timeIntervalSinceReferenceDate: 1_000))
        #expect(note.stamped(machineID: "work").id != note.stamped(machineID: "home").id)
        #expect(note.stamped(machineID: "work").rawID == note.rawID)
    }

    @Test("Unknown rich formatting and note colors preserve the plain body")
    func richTextFallback() throws {
        let note = try NotesTestPayload.note(title: "", body: "First line\nSecond line", extra: [
            "richBody": ["unsupported": true], "color": "future-color",
        ])
        #expect(String(note.richBody.characters) == "First line\nSecond line")
        #expect(note.displayTitle == "First line")
        #expect(note.color == .yellow)
    }

    @Test("Mac SwiftUI attributed text decodes with its formatting")
    func richTextRoundTrip() throws {
        var body = AttributedString("Important words")
        body.font = .body.bold()
        let encoded = try JSONEncoder().encode(RichNoteFixture(richBody: body))
        let note = try JSONDecoder().decode(RemoteNote.self, from: encoded)
        #expect(note.richBody == body)
        #expect(note.body == "Important words")
    }

    @Test("Action state is described without claiming an old launched agent is still running")
    func actionStatus() throws {
        let launched = try NotesTestPayload.note(extra: ["actions": [["title": "Research", "status": "started"]]])
        #expect(launched.statusLabel == "Linked to an agent")
        let failed = try NotesTestPayload.note(extra: ["actions": [["title": "Research", "status": "failed"]]])
        #expect(failed.statusLabel == "Action needs attention")
    }
}

@Suite("Shared notes store", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RemoteNotesStoreTests {
    @Test("Each machine owns its own notes even when UUIDs match")
    func machineIdentityIsAuthoritative() async throws {
        let store = RemoteNotesStore()
        let response = try NotesTestPayload.response(notes: [NotesTestPayload.note()])
        await store.refresh(machineIDs: ["work", "home"]) { _ in response }
        #expect(store.notes.count == 2)
        #expect(Set(store.notes.map(\.machineID)) == ["work", "home"])
        #expect(Set(store.notes.map(\.id)).count == 2)
    }

    @Test("Refresh updates open note identity and removes canonical deletions")
    func updatesAndDeletes() async throws {
        let store = RemoteNotesStore()
        let first = try NotesTestPayload.note(body: "Before")
        await store.refresh(machineIDs: ["work"]) { _ in try NotesTestPayload.response(notes: [first]) }
        let id = try #require(store.notes.first?.id)
        let updated = try NotesTestPayload.note(body: "Agent edited this", timestamp: 2_000)
        await store.refresh(machineIDs: ["work"]) { _ in try NotesTestPayload.response(notes: [updated]) }
        #expect(store.note(id: id)?.body == "Agent edited this")
        await store.refresh(machineIDs: ["work"]) { _ in try NotesTestPayload.response(notes: [], deleted: [first.rawID]) }
        #expect(store.note(id: id) == nil)
    }

    @Test("Offline machines retain last-loaded notes while healthy machines update")
    func partialFailureRetainsCache() async throws {
        let store = RemoteNotesStore()
        let first = try NotesTestPayload.response(notes: [NotesTestPayload.note(body: "Cached")])
        await store.refresh(machineIDs: ["work", "home"]) { _ in first }
        let refreshed = try NotesTestPayload.response(notes: [NotesTestPayload.note(body: "Fresh")])
        await store.refresh(machineIDs: ["work", "home"]) { id in
            if id == "home" { throw APIError.noActiveConnection(machineID: id) }
            return refreshed
        }
        #expect(store.notes.first(where: { $0.machineID == "home" })?.body == "Cached")
        #expect(store.notes.first(where: { $0.machineID == "work" })?.body == "Fresh")
        #expect(store.machineErrors["home"] != nil)
        #expect(store.machineErrors["work"] == nil)
        #expect(store.lastRefreshed["home"] != nil)
    }

    @Test("A slow Mac does not delay healthy notes becoming visible")
    func publishesHealthyMachineBeforeSlowOne() async throws {
        let store = RemoteNotesStore()
        let gate = NotesResponseGate()
        let response = try NotesTestPayload.response(notes: [NotesTestPayload.note()])
        var publications = Observations { store.notes.map(\.machineID) }.makeAsyncIterator()
        #expect(await publications.next() == [])

        let task = Task {
            await store.refresh(machineIDs: ["work", "slow"]) { id in
                if id == "slow" { return try await gate.wait() }
                return response
            }
        }
        defer {
            task.cancel()
            gate.cancel()
        }

        await waitUntilStarted(gate)
        var publishedMachineIDs: [String]?
        while let machineIDs = await publications.next() {
            guard !machineIDs.isEmpty else { continue }
            publishedMachineIDs = machineIDs
            break
        }

        #expect(publishedMachineIDs == ["work"])
        #expect(store.notes.map(\.machineID) == ["work"])
        #expect(!(await gate.isResolved))
        #expect(store.isRefreshing)

        await gate.resolve(response)
        await task.value
        #expect(Set(store.notes.map(\.machineID)) == ["work", "slow"])
        #expect(!store.isRefreshing)
    }

    @Test("An older overlapping refresh cannot overwrite a newer result")
    func overlappingRefreshesUseNewest() async throws {
        let store = RemoteNotesStore()
        let gate = NotesResponseGate()
        let oldTask = Task { await store.refresh(machineIDs: ["work"]) { _ in try await gate.wait() } }
        await waitUntilStarted(gate)
        let fresh = try NotesTestPayload.response(notes: [NotesTestPayload.note(body: "New")])
        await store.refresh(machineIDs: ["work"]) { _ in fresh }
        await gate.resolve(try NotesTestPayload.response(notes: [NotesTestPayload.note(body: "Old")]))
        await oldTask.value
        #expect(store.notes.first?.body == "New")
        #expect(!store.isRefreshing)
    }

    @Test("Reset prevents a prior account request from repopulating notes")
    func resetInvalidatesRequest() async throws {
        let store = RemoteNotesStore()
        let gate = NotesResponseGate()
        let task = Task { await store.refresh(machineIDs: ["work"]) { _ in try await gate.wait() } }
        await waitUntilStarted(gate)
        store.reset()
        await gate.resolve(try NotesTestPayload.response(notes: [NotesTestPayload.note()]))
        await task.value
        #expect(store.notes.isEmpty)
        #expect(store.lastRefreshed.isEmpty)
    }

    @Test("Search and machine filter work together and deleted IDs win over stale list rows")
    func filteringAndTombstones() async throws {
        let store = RemoteNotesStore()
        let note = try NotesTestPayload.note(title: "Release", body: "Review screenshots")
        await store.refresh(machineIDs: ["work", "home"]) { _ in try NotesTestPayload.response(notes: [note]) }
        #expect(store.visibleNotes(machineID: "work", search: "screenshots").count == 1)
        #expect(store.visibleNotes(machineID: "", search: "release").count == 2)
        #expect(store.visibleNotes(machineID: "home", search: "missing").isEmpty)
        await store.refresh(machineIDs: ["work"]) { _ in try NotesTestPayload.response(notes: [note], deleted: [note.rawID]) }
        #expect(store.notes.isEmpty)
    }

    @Test("A refresh started before saving cannot overwrite the saved note")
    func saveInvalidatesOlderRefresh() async throws {
        let store = RemoteNotesStore()
        let old = try NotesTestPayload.response(notes: [NotesTestPayload.note(body: "Old")])
        await store.refresh(machineIDs: ["work", "home"]) { _ in old }
        let gate = NotesResponseGate()
        let task = Task { await store.refresh(machineIDs: ["work", "home"]) { id in
            if id == "work" { return try await gate.wait() }
            return old
        } }
        await waitUntilStarted(gate)
        store.acceptSavedNote(try NotesTestPayload.note(body: "Saved").stamped(machineID: "work"))
        await gate.resolve(old)
        await task.value
        #expect(store.notes.first(where: { $0.machineID == "work" })?.body == "Saved")
        #expect(store.notes.first(where: { $0.machineID == "home" })?.body == "Old")
        #expect(!store.isRefreshing)
    }

    private func waitUntilStarted(_ gate: NotesResponseGate) async {
        #expect(await gate.waitUntilStarted())
    }
}

private enum NotesTestPayload {
    static let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func note(title: String = "Test note", body: String = "A full note", timestamp: Double = 1_000,
                     extra: [String: Any] = [:]) throws -> RemoteNote {
        var data: [String: Any] = ["id": id.uuidString, "title": title, "body": body, "color": "green",
                                   "createdAt": timestamp, "updatedAt": timestamp, "revision": 1, "actions": []]
        data.merge(extra, uniquingKeysWith: { _, new in new })
        return try JSONDecoder().decode(RemoteNote.self, from: JSONSerialization.data(withJSONObject: data))
    }

    static func response(notes: [RemoteNote], deleted: [UUID] = []) throws -> RemoteNotesResponse {
        RemoteNotesResponse(ok: true, revision: 1, notes: notes, deletedIDs: deleted)
    }
}

private actor NotesResponseGate {
    private let starts: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let responses: AsyncStream<RemoteNotesResponse>
    private let responseContinuation: AsyncStream<RemoteNotesResponse>.Continuation
    private var result: RemoteNotesResponse?
    private(set) var hasStarted = false
    private(set) var isResolved = false

    init() {
        let startPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        starts = startPair.stream
        startContinuation = startPair.continuation
        let responsePair = AsyncStream<RemoteNotesResponse>.makeStream(bufferingPolicy: .bufferingNewest(1))
        responses = responsePair.stream
        responseContinuation = responsePair.continuation
    }

    func wait() async throws -> RemoteNotesResponse {
        hasStarted = true
        startContinuation.yield(())
        if let result { return result }
        var iterator = responses.makeAsyncIterator()
        guard let response = await iterator.next() else { throw CancellationError() }
        return response
    }

    func waitUntilStarted() async -> Bool {
        if hasStarted { return true }
        var iterator = starts.makeAsyncIterator()
        return await iterator.next() != nil
    }

    func resolve(_ response: RemoteNotesResponse) {
        guard !isResolved else { return }
        result = response
        isResolved = true
        responseContinuation.yield(response)
        responseContinuation.finish()
        startContinuation.finish()
    }

    nonisolated func cancel() {
        startContinuation.finish()
        responseContinuation.finish()
    }
}

private struct RichNoteFixture: Encodable {
    let richBody: AttributedString
    private enum CodingKeys: String, CodingKey { case id, title, body, richBody, createdAt, updatedAt, color }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(NotesTestPayload.id, forKey: .id)
        try values.encode("Rich note", forKey: .title)
        try values.encode(String(richBody.characters), forKey: .body)
        try values.encode(richBody, forKey: .richBody, configuration: AttributeScopes.SwiftUIAttributes.self)
        try values.encode(1_000.0, forKey: .createdAt)
        try values.encode(1_000.0, forKey: .updatedAt)
        try values.encode("yellow", forKey: .color)
    }
}
