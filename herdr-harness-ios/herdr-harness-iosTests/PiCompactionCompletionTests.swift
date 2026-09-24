import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi compaction completion", .timeLimit(.minutes(1)))
@MainActor
struct PiCompactionCompletionTests {
    // MARK: - Evidence

    @Test("A persisted compaction entry reconstructs durable evidence")
    func persistedEntryEvidence() throws {
        let entry = try decode(
            #"{"type":"compaction","id":"compact-1","timestamp":"2030-01-01T12:00:00Z","summary":"Synthetic summary"}"#
        )
        let completion = try #require(PiCompactionCompletion(entry: entry, sessionID: "s1"))

        #expect(completion.evidence == .entry("compact-1"))
        #expect(completion.sessionID == "s1")
        #expect(completion.timestamp != nil)
        #expect(completion.statusMessage == "Context compacted")
        #expect(!completion.isAcknowledged)

        #expect(PiCompactionCompletion(entry: try decode(#"{"type":"message","id":"m1"}"#), sessionID: "s1") == nil)
        #expect(PiCompactionCompletion(entry: try decode(#"{"type":"compaction","summary":"no id"}"#), sessionID: "s1") == nil)
    }

    @Test("Only an explicit session_compact event is live success evidence")
    func eventEvidence() throws {
        let entryEvent = try envelope(
            9,
            #"{"type":"session_compact","reason":"manual","willRetry":false,"compactionEntry":{"type":"compaction","id":"compact-2","summary":"Synthetic summary"}}"#
        )
        let entryCompletion = try #require(PiCompactionCompletion(event: entryEvent, sessionID: "s1"))
        #expect(entryCompletion.evidence == .entry("compact-2"))
        #expect(entryCompletion.reason == .manual)

        let cursorEvent = try envelope(
            11,
            #"{"type":"session_compact","reason":"overflow","willRetry":true}"#
        )
        let cursorCompletion = try #require(PiCompactionCompletion(event: cursorEvent, sessionID: "s1"))
        #expect(cursorCompletion.evidence == .eventCursor("11"))
        #expect(cursorCompletion.reason == .overflow)

        for type in [
            #"{"type":"session_compact_end","reason":"manual","outcome":"completed"}"#,
            #"{"type":"session_compact_end","reason":"manual","outcome":"failed"}"#,
            #"{"type":"session_compact_end","reason":"manual","outcome":"aborted"}"#,
            #"{"type":"session_compact_end","reason":"manual","outcome":"settled"}"#,
            #"{"type":"session_before_compact","reason":"manual"}"#,
            #"{"type":"agent_settled"}"#,
        ] {
            #expect(PiCompactionCompletion(event: try envelope(12, type), sessionID: "s1") == nil)
        }
    }

    // MARK: - Reducer lifecycle

    @Test("A snapshot compaction entry reconstructs the cue and keeps its transcript notice")
    func snapshotReconstruction() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))

        let completion = try #require(reducer.compactionCompletion)
        #expect(completion.evidence == .entry("compact-1"))
        #expect(reducer.turns.flatMap(\.items).contains { item in
            guard case let .notice(notice) = item else { return false }
            return notice.id == "compact-1" && notice.title == "Context compacted"
        })
    }

    @Test("Duplicate snapshots do not duplicate the cue or its transcript notice")
    func duplicateSnapshotsDeduplicate() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1"), cursor: "6"))

        #expect(reducer.compactionCompletion?.evidence == .entry("compact-1"))
        #expect(reducer.turns.flatMap(\.items).filter { item in
            guard case let .notice(notice) = item else { return false }
            return notice.title == "Context compacted"
        }.count == 1)
    }

    @Test("Acknowledgement survives repeated snapshots until a newer compaction")
    func acknowledgementSurvivesRefreshes() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        reducer.acknowledgeCompactionCompletion()
        #expect(reducer.compactionCompletion?.isAcknowledged == true)

        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1"), cursor: "6"))
        #expect(reducer.compactionCompletion?.isAcknowledged == true)
        #expect(PiCompactionStatusPresentation.resolve(
            activity: nil,
            completion: reducer.compactionCompletion,
            readiness: readyReadiness
        ) == nil)

        reducer.replace(with: try snapshot(entries: compactionEntries(ids: ["compact-1", "compact-2"]), cursor: "7"))
        #expect(reducer.compactionCompletion?.evidence == .entry("compact-2"))
        #expect(reducer.compactionCompletion?.isAcknowledged == false)
    }

    @Test("A newer attempt suppresses the old cue and its failure cannot revive it")
    func failedAttemptDoesNotRevivePreviousCompletion() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        #expect(reducer.compactionCompletion != nil)

        _ = reducer.apply(try envelope(
            1,
            #"{"type":"session_before_compact","reason":"manual","willRetry":false}"#
        ))
        #expect(reducer.compactionCompletion == nil)
        #expect(reducer.compactionActivity != nil)

        for (cursor, outcome) in [(2, "failed"), (3, "aborted"), (4, "settled"), (5, "completed")] {
            _ = reducer.apply(try envelope(
                cursor,
                #"{"type":"session_compact_end","reason":"manual","outcome":"\#(outcome)"}"#
            ))
            #expect(reducer.compactionCompletion == nil)
        }

        // A later snapshot that still projects only the old entry must not
        // revive it as the failed attempt's success.
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1"), cursor: "6"))
        #expect(reducer.compactionCompletion == nil)

        // Only a persisted entry from a new success restores a cue.
        reducer.replace(with: try snapshot(entries: compactionEntries(ids: ["compact-1", "compact-2"]), cursor: "7"))
        #expect(reducer.compactionCompletion?.evidence == .entry("compact-2"))
    }

    @Test("An active snapshot compaction suppresses a carried completion")
    func activeSnapshotCompactionSuppresses() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))

        reducer.replace(with: try snapshot(
            entries: compactionEntry(id: "compact-1"),
            cursor: "6",
            state: #"{"isStreaming":true,"isCompacting":true,"compaction":{"active":true,"reason":"manual"}}"#
        ))

        #expect(reducer.compactionActivity != nil)
        #expect(reducer.compactionCompletion == nil)
    }

    @Test("A session change clears the cue, its acknowledgement, and suppression")
    func sessionChangeClearsScope() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        reducer.acknowledgeCompactionCompletion()

        // A different session's envelope is refused without an authoritative
        // reload, and the recovery candidate starts a fresh scope.
        #expect(reducer.apply(try envelope(1, #"{"type":"session_switch","id":"s2"}"#)) == .needsSnapshot)
        #expect(reducer.compactionCompletion?.evidence == .entry("compact-1"))

        reducer.replace(
            with: try snapshot(entries: "[]", cursor: "2", sessionID: "s2"),
            allowsCompactionCarryOver: false
        )
        #expect(reducer.compactionCompletion == nil)
        #expect(reducer.acknowledgedCompactionEvidence == nil)

        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-2"), cursor: "3", sessionID: "s2"))
        #expect(reducer.compactionCompletion?.evidence == .entry("compact-2"))
        #expect(reducer.compactionCompletion?.isAcknowledged == false)
    }

    @Test("A branch boundary stops a truncated snapshot from carrying the old cue")
    func branchBoundaryDoesNotCarryCompletion() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))

        reducer.replace(
            with: try snapshot(entries: "[]", cursor: "6"),
            allowsCompactionCarryOver: false
        )

        #expect(reducer.compactionCompletion == nil)
    }

    @Test("Pending event evidence fills a truncated snapshot and deduplicates by entry")
    func pendingEvidence() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: "[]"))

        let cursorEvent = try envelope(2, #"{"type":"session_compact","reason":"threshold","willRetry":false}"#)
        let pending = try #require(PiCompactionCompletion(event: cursorEvent, sessionID: "s1"))
        reducer.replace(
            with: try snapshot(entries: "[]", cursor: "2"),
            pendingCompactionCompletion: pending
        )
        #expect(reducer.compactionCompletion?.evidence == .eventCursor("2"))
        #expect(reducer.compactionCompletion?.reason == .threshold)

        var deduped = PiConversationReducer()
        let entryEvent = try envelope(
            3,
            #"{"type":"session_compact","reason":"overflow","compactionEntry":{"type":"compaction","id":"compact-9"}}"#
        )
        let entryPending = try #require(PiCompactionCompletion(event: entryEvent, sessionID: "s1"))
        deduped.replace(
            with: try snapshot(entries: compactionEntry(id: "compact-9"), cursor: "3"),
            pendingCompactionCompletion: entryPending
        )
        #expect(deduped.compactionCompletion?.evidence == .entry("compact-9"))
        #expect(deduped.compactionCompletion?.reason == .overflow)

        // Evidence captured in another session never leaks into this one.
        var switched = PiConversationReducer()
        switched.replace(with: try snapshot(entries: "[]"))
        switched.replace(
            with: try snapshot(entries: "[]", cursor: "4", sessionID: "s2"),
            pendingCompactionCompletion: pending,
            allowsCompactionCarryOver: false
        )
        #expect(switched.compactionCompletion == nil)
    }

    @Test("A newer success replaces an acknowledged older cue")
    func newerSuccessReplacesAcknowledgedCue() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        reducer.acknowledgeCompactionCompletion()

        let pending = try #require(PiCompactionCompletion(
            event: try envelope(9, #"{"type":"session_compact","reason":"manual"}"#),
            sessionID: "s1"
        ))
        reducer.replace(
            with: try snapshot(entries: "[]", cursor: "9"),
            pendingCompactionCompletion: pending
        )

        #expect(reducer.compactionCompletion?.evidence == .eventCursor("9"))
        #expect(reducer.compactionCompletion?.isAcknowledged == false)
    }

    // MARK: - Composer configuration and presentation

    @Test("An acknowledged completion disappears from the composer status area")
    func acknowledgedCompletionHides() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try snapshot(entries: compactionEntry(id: "compact-1")))
        reducer.acknowledgeCompactionCompletion()

        let configuration = PiPromptComposerConfiguration(
            capabilities: Self.capabilities,
            phase: .idle,
            compactionActivity: nil,
            compactionCompletion: reducer.compactionCompletion,
            isConnected: true,
            isSubmitting: false,
            isAborting: false,
            currentModel: nil,
            availableModels: [],
            isLoadingModels: false,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: false,
            submit: { _, _ in true },
            abort: { true },
            selectModel: { _ in true },
            retryLoadModels: {},
            thinkingLevel: nil,
            isSettingThinkingLevel: false,
            selectThinkingLevel: { _ in true }
        )

        #expect(configuration.compactionPresentation == nil)
        #expect(configuration.availableDispositions == [.prompt])

        var unacknowledged = reducer
        unacknowledged.replace(with: try snapshot(entries: compactionEntry(id: "compact-2"), cursor: "9"))
        let visible = try #require(PiCompactionStatusPresentation.resolve(
            activity: nil,
            completion: unacknowledged.compactionCompletion,
            readiness: readyReadiness
        ))
        #expect(visible.kind == .completed)
        #expect(visible.title == "Context compacted")
        #expect(visible.detail == "Ready for your next message.")
        #expect(visible.systemImage == "checkmark.circle.fill")
        #expect(visible.accessibilityIdentifier == "pi-chat-compacted")
    }

    // MARK: - Store submission

    @Test("An accepted submission dismisses only the composer cue")
    func acceptedSubmissionAcknowledgesCue() async throws {
        let store = PiConversationStore()
        let pane = testPane()
        var streamContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        let (published, publishedContinuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in publishedContinuation.yield(()) }
        store.snapshotProvider = { _ in
            try self.snapshot(entries: self.compactionEntry(id: "compact-1"))
        }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { streamContinuation = $0 }
        }
        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            streamContinuation?.finish()
            publishedContinuation.finish()
        }

        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()
        #expect(store.compactionCompletion?.evidence == .entry("compact-1"))
        #expect(store.canSendCommands)
        let noticeBefore = transcriptNoticeCount(in: store)

        var submitted: [(text: String, disposition: PiPromptDisposition)] = []
        store.submitProvider = { text, disposition, _ in
            submitted.append((text, disposition))
        }
        let accepted = await store.submit(
            text: "Synthetic follow-up",
            disposition: .prompt,
            model: HerdrAppModel(arguments: []),
            pane: pane
        )

        #expect(accepted)
        #expect(submitted.count == 1)
        #expect(submitted.first?.text == "Synthetic follow-up")
        #expect(store.compactionCompletion?.isAcknowledged == true)
        #expect(store.compactionPresentationForTests == nil)
        // The composer cue is dismissed; the durable transcript notice stays.
        #expect(transcriptNoticeCount(in: store) == noticeBefore)

        task.cancel()
        streamContinuation?.finish()
        await task.value
    }

    @Test("A failed submission leaves the completion cue in place")
    func failedSubmissionRetainsCue() async throws {
        let store = PiConversationStore()
        let pane = testPane()
        var streamContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        let (published, publishedContinuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in publishedContinuation.yield(()) }
        store.snapshotProvider = { _ in
            try self.snapshot(entries: self.compactionEntry(id: "compact-1"))
        }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { streamContinuation = $0 }
        }
        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            streamContinuation?.finish()
            publishedContinuation.finish()
        }
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()

        store.submitProvider = { _, _, _ in
            throw APIError.server(status: 500, message: "Synthetic failure")
        }
        let accepted = await store.submit(
            text: "Synthetic follow-up",
            disposition: .prompt,
            model: HerdrAppModel(arguments: []),
            pane: pane
        )

        #expect(!accepted)
        #expect(store.lastError == "Synthetic failure")
        #expect(store.compactionCompletion?.isAcknowledged == false)
        #expect(store.compactionPresentationForTests?.kind == .completed)

        task.cancel()
        streamContinuation?.finish()
        await task.value
    }

    // MARK: - Helpers

    private static let capabilities = PiSemanticCapabilities(
        prompt: true,
        steer: true,
        followUp: true,
        abort: true,
        listModels: false,
        setModel: false,
        setThinkingLevel: false,
        interactionResponse: false
    )

    private var readyReadiness: PiCompactionReadiness {
        PiCompactionReadiness(isConnected: true, phase: .idle, availableDispositions: [.prompt])
    }

    private func transcriptNoticeCount(in store: PiConversationStore) -> Int {
        store.turns.flatMap(\.items).filter { item in
            guard case let .notice(notice) = item else { return false }
            return notice.title == "Context compacted"
        }.count
    }

    private func testPane() -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1", terminalID: "w1:p1", workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }

    private func decode(_ json: String) throws -> PiJSONValue {
        try JSONDecoder().decode(PiJSONValue.self, from: Data(json.utf8))
    }

    private func envelope(
        _ cursor: Int,
        _ json: String,
        sessionID: String = "s1"
    ) throws -> PiConversationEnvelope {
        PiConversationEnvelope(
            paneID: "w1:p1",
            sessionID: sessionID,
            cursor: String(cursor),
            event: try decode(json)
        )
    }

    private func compactionEntry(id: String) -> String {
        """
        [
          {
            "type":"compaction",
            "id":"\(id)",
            "timestamp":"2030-01-01T12:00:00Z",
            "summary":"Synthetic summary",
            "firstKeptEntryId":"u1"
          }
        ]
        """
    }

    private func compactionEntries(ids: [String]) -> String {
        "[" + ids.map { id in
            #"{"type":"compaction","id":"\#(id)","timestamp":"2030-01-01T12:00:00Z","summary":"Synthetic summary","firstKeptEntryId":"u1"}"#
        }.joined(separator: ",") + "]"
    }

    private func snapshot(
        entries: String,
        cursor: String = "0",
        sessionID: String = "s1",
        state: String = #"{"isStreaming":false,"context":{"tokens":1}}"#,
        connected: Bool = true
    ) throws -> PiConversationSnapshot {
        try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "pane_id":"w1:p1","available":true,"connected":\(connected),
                  "session":{"id":"\(sessionID)"},"state":\(state),"entries":\(entries),
                  "pending_interactions":[],"cursor":"\(cursor)","latest_cursor":"\(cursor)",
                  "oldest_cursor":"0","truncated":false
                }
                """.utf8
            )
        )
    }
}

@MainActor
private extension PiConversationStore {
    /// Mirrors the composer configuration's readiness for store-level tests.
    var compactionPresentationForTests: PiCompactionStatusPresentation? {
        PiCompactionStatusPresentation.resolve(
            activity: compactionActivity,
            completion: compactionCompletion,
            readiness: PiCompactionReadiness(
                isConnected: canSendCommands,
                phase: phase,
                availableDispositions: compactionActivity == nil
                    ? [.prompt]
                    : []
            )
        )
    }
}
