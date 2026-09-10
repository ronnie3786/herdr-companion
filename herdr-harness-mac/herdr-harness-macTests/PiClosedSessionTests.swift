import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Closed Pi conversations", .serialized)
@MainActor
struct PiClosedSessionTests {
    @Test("Only confirmed session changes retain history; reconnect and compaction do not")
    func sessionBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        let pane = testPane()
        let model = HerdrAppModel(arguments: [])
        store.eventsProvider = { _, _ in AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        store.snapshotProvider = { _ in try snapshot(id: "old-session", prompt: "Keep this message") }
        await store.follow(model: model, pane: pane)
        await store.follow(model: model, pane: pane)
        #expect(store.closedSessions.isEmpty)
        store.snapshotProvider = { _ in try snapshot(id: "new-session", prompt: "") }
        await store.follow(model: model, pane: pane)
        #expect(store.sessionID == "new-session")
        #expect(store.turns.isEmpty)
        let closed = try #require(store.closedSessions.first)
        #expect(closed.id == "old-session")
        #expect(closed.entries.first?.text == "Keep this message")
        #expect(store.closedSessions.count == 1)
        await store.follow(model: model, pane: pane)
        #expect(store.closedSessions.count == 1)
        store.reset()
        #expect(store.closedSessions.isEmpty)
        await store.follow(model: model, pane: pane)
        #expect(store.closedSessions == [closed])
        #expect(try store.sessionArchive.load(scope: "another-machine|another-pane").isEmpty)
    }

    @Test("Unreadable archives are preserved rather than overwritten")
    func corruptArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = PiClosedSessionArchive(directory: root)
        let pane = testPane()
        let url = archive.fileURL(scope: pane.id)
        try Data("corrupt fixture".utf8).write(to: url)
        let store = PiConversationStore()
        store.sessionArchive = archive
        store.eventsProvider = { _, _ in AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        store.snapshotProvider = { _ in try snapshot(id: "one", prompt: "Original") }
        let model = HerdrAppModel(arguments: [])
        await store.follow(model: model, pane: pane)
        store.snapshotProvider = { _ in try snapshot(id: "two", prompt: "") }
        await store.follow(model: model, pane: pane)
        #expect(store.historyError != nil)
        #expect(store.closedSessions.count == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt fixture")
    }

    private func testPane() -> HerdrPane {
        HerdrPane(paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "", focused: true,
                  agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil, label: nil, title: nil,
                  agent: nil, displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil)
    }

    private func snapshot(id: String, prompt: String) throws -> PiConversationSnapshot {
        let entries = prompt.isEmpty ? "[]" : """
        [{"type":"message","id":"u1","message":{"role":"user","content":"\(prompt)"}}]
        """
        return try JSONDecoder().decode(PiConversationSnapshot.self, from: Data("""
        {"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","available":true,"connected":true,"session":{"id":"\(id)"},"state":{"context":{"tokens":1}},"entries":\(entries),"pending_interactions":[],"cursor":"1","latest_cursor":"1","oldest_cursor":"1","truncated":false}
        """.utf8))
    }
}
