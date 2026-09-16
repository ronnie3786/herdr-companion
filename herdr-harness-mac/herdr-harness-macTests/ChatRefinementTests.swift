import AppKit
import SwiftUI
import Testing
import Vision
@testable import herdr_harness_mac

@Suite("Chat response scope and new-session flow", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatRefinementTests {
    private let oldID = "00000000-0000-0000-0000-000000000101"
    private let newID = "00000000-0000-0000-0000-000000000102"

    @Test("New-chat command captures history before an empty checkpoint and confirms without SSE")
    func newSessionFlowAndProof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HerdrRenderFixtures.demoModel()
        let pane = try HerdrRenderFixtures.piCapablePane().stamped(machineID: "demo1")
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.newSessionPollInterval = .milliseconds(1)
        store.eventsProvider = { _, _ in AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        let old = try snapshot(sessionID: oldID)
        let cleared = try snapshot(sessionID: oldID, empty: true)
        let fresh = try snapshot(sessionID: newID, empty: true)
        store.snapshotProvider = { _ in old }
        await store.follow(model: model, pane: pane)
        let original = store.turns
        var commandCount = 0
        store.newSessionCommand = { target in
            #expect(target.id == pane.id)
            #expect(store.isStartingNewSession)
            #expect(!store.canSendCommands)
            #expect(store.closedSessions.isEmpty)
            commandCount += 1
            // Pi can clear the transcript before its new identity propagates.
            store.snapshotProvider = { _ in cleared }
            await store.follow(model: model, pane: pane)
            // A same-pane transport restart must retain the committed prefix;
            // only the confirmed new identity below may close the chapter.
            #expect(store.turns == original)
            store.snapshotProvider = { _ in fresh }
        }
        await store.startNewSession(model: model, pane: pane)
        #expect(commandCount == 1)
        #expect(store.sessionID == newID)
        #expect(store.turns.isEmpty)
        #expect(!store.isStartingNewSession)
        #expect(store.newSessionError == nil)
        #expect(store.canSendCommands)
        #expect(store.sessionBoundaryRevision == 1)
        let archived = try #require(store.closedSessions.first)
        #expect(archived.entries == PiClosedSession(id: oldID, turns: original, wasTruncated: false).entries)
        #expect(try store.sessionArchive.load(scope: pane.id) == store.closedSessions)
        let image = try await HerdrRenderHarness.render("proof-new-pi-chat.png", size: CGSize(width: 1020, height: 900)) {
            VStack(spacing: 0) {
                HStack {
                    Text("Garden planning · New Pi chat").herdrFont(.headline)
                    Spacer()
                    Text("Synthetic demo · confirmed session change").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                }.padding(20)
                PiChatView(model: model, store: store, paneID: pane.id, interactionResponseAvailable: false,
                           composerPane: pane, workspace: workspace, draft: .constant(""), attachments: .constant([]),
                           focusRequest: 0, interactionResponder: PiInteractionResponder(), modelFavorites: ModelFavoritesStore())
            }
        }
        image.expectSubstantial()
        // Assert visible content, not just archive state or PNG file size. A
        // hidden timeline can still produce a substantial image of its chrome.
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: image.url)))
        let fullImage = try #require(bitmap.cgImage)
        let middle = try #require(fullImage.cropping(to: CGRect(x: 0, y: fullImage.height / 3,
                                                               width: fullImage.width, height: fullImage.height / 3)))
        // Small metadata can fall below the OCR detector's effective scale on
        // CI's virtual display. Also inspect the boundary's central band at its
        // native resolution; retain every visibility assertion below.
        var visibleText = ""
        for image in [fullImage, middle] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.005
            try HerdrOCR.perform(request, image: image)
            visibleText += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") + " "
        }
        #expect(visibleText.contains("Previous session"))
        #expect(visibleText.contains("New conversation"))
        #expect(visibleText.contains("mint"))
    }

    @Test("New-chat confirmation wakes a silent old live stream")
    func newSessionWakesSilentStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.newSessionPollInterval = .milliseconds(1)
        store.newSessionPollAttempts = 200
        let pane = try HerdrRenderFixtures.piCapablePane()
        let model = HerdrRenderFixtures.demoModel()
        let old = try snapshot(sessionID: oldID)
        let fresh = try snapshot(sessionID: newID, empty: true)
        var requestedNew = false
        var streams = 0
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (terminated, terminationContinuation) = AsyncStream<Void>.makeStream()
        store.snapshotProvider = { _ in requestedNew ? fresh : old }
        store.eventsProvider = { _, _ in
            streams += 1
            if streams == 1 {
                return AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in terminationContinuation.yield(()) }
                    startedContinuation.yield(())
                }
            }
            return AsyncThrowingStream { _ in }
        }
        store.newSessionCommand = { _ in requestedNew = true }

        let follow = Task { @MainActor in await store.follow(model: model, pane: pane) }
        defer {
            follow.cancel()
            startedContinuation.finish()
            terminationContinuation.finish()
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        for _ in 0..<10 { await Task.yield() }
        await store.startNewSession(model: model, pane: pane)
        var terminatedIterator = terminated.makeAsyncIterator()
        _ = await terminatedIterator.next()

        #expect(store.sessionID == newID)
        #expect(store.closedSessions.count == 1)
        #expect(streams == 2)

        follow.cancel()
        await follow.value
    }

    @Test("New-chat confirmation cancels polling, catches up atomically, and resumes live delivery")
    func newSessionSupersedesPollingAndResumesLive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.newSessionPollInterval = .milliseconds(1)
        store.newSessionPollAttempts = 200
        store.offlineSnapshotPollInterval = .seconds(60)
        store.reconnectBackoffBase = .zero
        let pane = try HerdrRenderFixtures.piCapablePane()
        let model = HerdrRenderFixtures.demoModel()
        let old = try snapshot(sessionID: oldID, connected: false)
        let fresh = try snapshot(sessionID: newID, cursor: "1", latest: "2", prompt: "New prompt")
        var requestedNew = false
        var streams = 0
        let (published, continuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in
            if store.turns.contains(where: { $0.user?.text == "Live delivery" }) {
                continuation.yield(())
            }
        }
        store.snapshotProvider = { _ in requestedNew ? fresh : old }
        store.eventsProvider = { _, cursor in
            streams += 1
            if cursor == "1" {
                return AsyncThrowingStream { stream in
                    stream.yield(.envelope(PiConversationEnvelope(
                        paneID: pane.paneID, sessionID: newID, cursor: "2",
                        event: .object([
                            "type": .string("message_start"),
                            "message": .object([
                                "id": .string("caught-up-user"),
                                "role": .string("user"),
                                "content": .string("Caught up atomically")
                            ])
                        ])
                    )))
                }
            }
            return AsyncThrowingStream { stream in
                stream.yield(.envelope(PiConversationEnvelope(
                    paneID: pane.paneID, sessionID: newID, cursor: "3",
                    event: .object([
                        "type": .string("message_start"),
                        "message": .object([
                            "id": .string("live-user"),
                            "role": .string("user"),
                            "content": .string("Live delivery")
                        ])
                    ])
                )))
            }
        }
        store.newSessionCommand = { _ in requestedNew = true }

        let follow = Task { @MainActor in await store.follow(model: model, pane: pane) }
        defer {
            follow.cancel()
            continuation.finish()
        }
        for _ in 0..<100 where store.sessionID != oldID { await Task.yield() }
        #expect(store.sessionID == oldID)
        await store.startNewSession(model: model, pane: pane)
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()

        #expect(store.sessionID == newID)
        #expect(store.turns.first?.user?.text == "New prompt")
        #expect(store.turns.contains(where: { $0.user?.text == "Caught up atomically" }))
        #expect(store.turns.contains(where: { $0.user?.text == "Live delivery" }))
        #expect(store.closedSessions.count == 1)
        #expect(store.closedSessions.first?.id == oldID)
        #expect(streams == 2)

        follow.cancel()
        await follow.value
    }

    @Test("Failed new-chat commands do not fabricate closed history")
    func failedReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        let model = HerdrRenderFixtures.demoModel()
        let pane = try HerdrRenderFixtures.piCapablePane()
        let old = try snapshot(sessionID: oldID)
        store.snapshotProvider = { _ in old }
        store.eventsProvider = { _, _ in AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        await store.follow(model: model, pane: pane)
        store.newSessionCommand = { _ in throw APIError.invalidResponse }
        await store.startNewSession(model: model, pane: pane)
        #expect(store.closedSessions.isEmpty)
        #expect(store.sessionID == oldID)
        #expect(store.newSessionError != nil)
        #expect(store.canSendCommands)
        store.newSessionCommand = { _ in }
        store.newSessionPollAttempts = 1
        store.newSessionPollInterval = .milliseconds(1)
        await store.startNewSession(model: model, pane: pane)
        #expect(store.hasUnconfirmedNewSession)
        #expect(!store.canSendCommands)
        #expect(store.closedSessions.isEmpty)
        let fresh = try snapshot(sessionID: newID, empty: true)
        store.snapshotProvider = { _ in fresh }
        var shouldReset = true
        store.eventsProvider = { _, _ in
            guard shouldReset else {
                return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
            }
            shouldReset = false
            return AsyncThrowingStream { continuation in
                continuation.yield(.envelope(PiConversationEnvelope(
                    paneID: pane.paneID, sessionID: oldID, cursor: "1",
                    event: .object([
                        "type": .string("stream.reset"),
                        "reason": .string("session_changed")
                    ])
                )))
                continuation.finish()
            }
        }
        await store.follow(model: model, pane: pane)
        #expect(!store.hasUnconfirmedNewSession)
        #expect(store.closedSessions.count == 1)
        #expect(store.closedSessions.first?.id == oldID)
    }

    @Test("Recent completed assistant outputs are eligible, never users or streaming text")
    func quoteScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try snapshot(sessionID: oldID)
        var reducer = PiConversationReducer()
        reducer.replace(with: snapshot)
        let eligible = ChatQuoteEligibility.assistantIDs(in: reducer.turns)
        #expect(eligible.count == 2)
        #expect(eligible.contains { $0.contains("answer-two") })
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        await store.follow(model: HerdrRenderFixtures.demoModel(), pane: try HerdrRenderFixtures.piCapablePane())
        let host = NSHostingView(rootView: PiChatTimelineView(store: store, isConnected: true) { _, _ in true }
            .environment(\.saveChatQuote, { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let selectable = descendants(host).compactMap { $0 as? ChatSelectionTextView }.filter { $0.saveQuote != nil }
        #expect(selectable.count == 2)
        #expect(selectable.contains { $0.string == "Use a wide planter for basil, with mint in its own pot. The planting plan is ready for your next question." })
        var turns = reducer.turns
        turns[turns.count - 1].items.append(.assistant(PiAssistantBlock(id: "in-progress", text: "A newer answer…", status: .streaming)))
        #expect(ChatQuoteEligibility.assistantIDs(in: turns) == eligible)
        for id in ["third", "fourth"] {
            turns[turns.count - 1].items.append(.assistant(PiAssistantBlock(id: id, text: id, status: .complete)))
            turns[turns.count - 1].items.append(.assistant(PiAssistantBlock(id: "empty-\(id)", text: " ", status: .complete)))
        }
        let lastThree = ChatQuoteEligibility.assistantIDs(in: turns)
        #expect(lastThree.count == 3)
        #expect(lastThree.contains("third"))
        #expect(lastThree.contains("fourth"))
        #expect(!lastThree.contains { $0.contains("answer-one") })
    }

    private func snapshot(
        sessionID: String,
        empty: Bool = false,
        streaming: Bool = false,
        connected: Bool = true,
        cursor: String = "1",
        latest: String = "1",
        prompt: String? = nil
    ) throws -> PiConversationSnapshot {
        let entries: [[String: Any]] = empty ? [] : prompt.map {
            [["type": "message", "id": "question-new", "message": ["role": "user", "content": $0]]]
        } ?? [
            ["type": "message", "id": "question-one", "message": ["role": "user", "content": "Help me plan a small herb garden."]],
            ["type": "message", "id": "answer-one", "message": ["role": "assistant", "content": [["type": "text", "text": "Choose basil, parsley, and mint for a simple first garden."]]]],
            ["type": "message", "id": "question-two", "message": ["role": "user", "content": "Which pots should I use?"]],
            ["type": "message", "id": "answer-two", "message": ["role": "assistant", "content": [["type": "text", "text": "Use a wide planter for basil, with mint in its own pot. The planting plan is ready for your next question."]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "protocol": ["name": "herdr.pi.semantic", "version": 1], "pane_id": "w1:p1",
            "available": true, "connected": connected, "session": ["id": sessionID],
            "state": ["context": ["tokens": 0], "isStreaming": streaming,
                      "model": ["provider": "anthropic", "id": "claude-sonnet-4-5", "name": "Sonnet 4.5"], "thinkingLevel": "high"], "entries": entries,
            "pending_interactions": [], "cursor": cursor, "latest_cursor": latest, "oldest_cursor": "1", "truncated": false
        ])
        return try JSONDecoder().decode(PiConversationSnapshot.self, from: data)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
