import Foundation
import Testing
@testable import herdr_harness_mac

private actor PiSnapshotGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var released = false

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        guard !released else { return }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        released = true
        continuation.yield(())
        continuation.finish()
    }
}

@Suite("Pi conversation reconnect state machine", .timeLimit(.minutes(1)))
@MainActor
struct PiConversationStoreReloadGuardTests {
    @Test("Overflow, disconnect, and EOF retry the applied cursor without refetching")
    func transientFailuresRetainCommittedPrefix() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        let pane = testPane()
        var snapshotCalls = 0
        var cursors: [String?] = []
        var publishedTools: [[ToolState]] = []
        let (requests, requestContinuation) = AsyncStream<Int>.makeStream()
        let (publishedCosts, publishedCostContinuation) = AsyncStream<Double>.makeStream()

        store.snapshotProvider = { _ in
            snapshotCalls += 1
            return try snapshot(cursor: "1", latest: "1", cost: 1, toolCallID: "committed-tool")
        }
        store.publishObserver = { cost, _ in
            publishedTools.append(toolStates(in: store))
            if let totalUSD = cost?.totalUSD { publishedCostContinuation.yield(totalUSD) }
        }
        store.eventsProvider = { _, cursor in
            cursors.append(cursor)
            requestContinuation.yield(cursors.count)
            switch cursors.count {
            case 1:
                return AsyncThrowingStream { continuation in
                    continuation.yield(try! streamEvent(2, #"{"type":"turn_end","cost":{"totalUSD":2,"totalTokens":20}}"#))
                    continuation.yield(try! streamEvent(3, #"{"type":"agent_settled"}"#))
                    continuation.finish(throwing: APIError.streamBacklogOverflow)
                }
            case 2:
                return AsyncThrowingStream { $0.finish(throwing: APIError.streamEnded) }
            case 3:
                return AsyncThrowingStream { $0.finish() }
            default:
                return AsyncThrowingStream { _ in }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            requestContinuation.finish()
            publishedCostContinuation.finish()
        }

        var iterator = requests.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        #expect(await iterator.next() == 4)
        var publishedCostIterator = publishedCosts.makeAsyncIterator()
        #expect(await publishedCostIterator.next() == 1)
        #expect(await publishedCostIterator.next() == 2)
        #expect(snapshotCalls == 1)
        #expect(cursors == ["1", "3", "3", "3"])
        #expect(store.sessionCost?.totalUSD == 2)
        #expect(!publishedTools.isEmpty)
        #expect(publishedTools.allSatisfy { $0 == [ToolState(id: "committed-tool", status: .succeeded)] })
        #expect(toolStates(in: store) == [ToolState(id: "committed-tool", status: .succeeded)])

        task.cancel()
        await task.value
    }

    @Test("Reset catch-up stays private through more than 512 envelopes")
    func catchUpPublishesOnlyAtFiniteWatermark() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        let pane = testPane()
        var snapshotCalls = 0
        var streamCalls = 0
        var catchUpContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        var publishedCosts: [Double] = []
        var publishedTools: [[ToolState]] = []
        var privateReplayTools: [[ToolState]] = []
        let (progress, progressContinuation) = AsyncStream<String>.makeStream()
        let (publishes, publishContinuation) = AsyncStream<Double>.makeStream()

        store.snapshotProvider = { _ in
            snapshotCalls += 1
            if snapshotCalls == 1 {
                return try snapshot(cursor: "1", latest: "1", cost: 10, prompt: "Stable", toolCallID: "committed-tool")
            }
            return try snapshot(cursor: "1", latest: "520", cost: 1, prompt: "Stable", toolCallID: "candidate-tool")
        }
        store.publishObserver = { cost, _ in
            guard let value = cost?.totalUSD else { return }
            publishedCosts.append(value)
            publishedTools.append(toolStates(in: store))
            publishContinuation.yield(value)
        }
        store.recoveryProgress = { cursor in
            privateReplayTools.append(toolStates(in: store))
            if cursor == "519" { progressContinuation.yield("519") }
        }
        store.eventsProvider = { _, _ in
            streamCalls += 1
            if streamCalls == 1 {
                return AsyncThrowingStream { continuation in
                    continuation.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1",
                        sessionID: "s1",
                        cursor: "520",
                        event: .object([
                            "type": .string("stream.reset"),
                            "reason": .string("replay_gap")
                        ])
                    )))
                    continuation.finish()
                }
            }
            return AsyncThrowingStream { continuation in
                catchUpContinuation = continuation
                continuation.yield(try! streamEvent(
                    2,
                    #"{"type":"tool_execution_start","toolCallId":"candidate-tool","toolName":"read","args":{"path":"Synthetic.swift"}}"#
                ))
                continuation.yield(try! streamEvent(
                    3,
                    #"{"type":"tool_execution_end","toolCallId":"candidate-tool","toolName":"read","result":{"content":"synthetic"},"isError":false}"#
                ))
                for cursor in 4...519 {
                    continuation.yield(try! streamEvent(
                        cursor,
                        #"{"type":"turn_end","cost":{"totalUSD":1,"totalTokens":1}}"#
                    ))
                }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            catchUpContinuation?.finish()
            progressContinuation.finish()
            publishContinuation.finish()
        }

        var publishIterator = publishes.makeAsyncIterator()
        #expect(await publishIterator.next() == 10)
        var progressIterator = progress.makeAsyncIterator()
        #expect(await progressIterator.next() == "519")
        #expect(publishedCosts == [10])
        #expect(store.sessionCost?.totalUSD == 10)
        #expect(publishedTools == [[ToolState(id: "committed-tool", status: .succeeded)]])
        #expect(!privateReplayTools.isEmpty)
        #expect(privateReplayTools.allSatisfy { $0 == [ToolState(id: "committed-tool", status: .succeeded)] })

        let continuation = try #require(catchUpContinuation)
        continuation.yield(try streamEvent(
            520,
            #"{"type":"turn_end","cost":{"totalUSD":20,"totalTokens":200}}"#
        ))
        #expect(await publishIterator.next() == 20)
        #expect(publishedCosts == [10, 20])
        #expect(store.sessionCost?.totalUSD == 20)
        #expect(store.turns.first?.user?.text == "Stable")
        #expect(publishedTools == [
            [ToolState(id: "committed-tool", status: .succeeded)],
            [ToolState(id: "candidate-tool", status: .succeeded)]
        ])
        #expect(toolStates(in: store) == [ToolState(id: "candidate-tool", status: .succeeded)])

        task.cancel()
        await task.value
    }

    @Test("A reset during catch-up discards the candidate before publishing")
    func resetDuringCatchUpRestartsTransaction() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var snapshots = 0
        var streams = 0
        var publishedCosts: [Double] = []
        let (publishes, publishContinuation) = AsyncStream<Double>.makeStream()
        store.publishObserver = { cost, _ in
            if let value = cost?.totalUSD {
                publishedCosts.append(value)
                publishContinuation.yield(value)
            }
        }
        store.snapshotProvider = { _ in
            snapshots += 1
            switch snapshots {
            case 1: return try snapshot(cursor: "1", latest: "1", cost: 10, prompt: "Committed")
            case 2: return try snapshot(cursor: "1", latest: "5", cost: 1, prompt: "Never publish")
            default: return try snapshot(cursor: "1", latest: "1", cost: 2, prompt: "Restarted")
            }
        }
        store.eventsProvider = { _, _ in
            streams += 1
            switch streams {
            case 1:
                return resetStream(reason: "replay_gap", cursor: "5")
            case 2:
                return AsyncThrowingStream { continuation in
                    continuation.yield(try! streamEvent(2, #"{"type":"turn_end","cost":{"totalUSD":1}}"#))
                    continuation.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1", sessionID: "s1", cursor: "5",
                        event: .object([
                            "type": .string("stream.reset"),
                            "reason": .string("backend_restarted")
                        ])
                    )))
                    continuation.finish()
                }
            default:
                return AsyncThrowingStream { _ in }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer {
            task.cancel()
            publishContinuation.finish()
        }
        var iterator = publishes.makeAsyncIterator()
        #expect(await iterator.next() == 10)
        #expect(await iterator.next() == 2)
        #expect(publishedCosts == [10, 2])
        #expect(store.turns.first?.user?.text == "Restarted")
        task.cancel()
        await task.value
    }

    @Test("Backend restart may intentionally replace a newer cursor with an older snapshot")
    func backendRestartAllowsAuthoritativeRegression() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        let pane = testPane()
        var snapshots = 0
        var streams = 0
        let (publishes, publishContinuation) = AsyncStream<Double>.makeStream()
        store.publishObserver = { cost, _ in
            if let value = cost?.totalUSD { publishContinuation.yield(value) }
        }
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(cursor: "100", latest: "100", cost: 100, prompt: "Before restart")
                : try snapshot(cursor: "1", latest: "3", cost: 1, prompt: "After restart")
        }
        store.eventsProvider = { _, _ in
            streams += 1
            if streams == 1 {
                return AsyncThrowingStream { continuation in
                    continuation.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1", sessionID: "s1", cursor: "1",
                        event: .object([
                            "type": .string("stream.reset"),
                            "reason": .string("backend_restarted")
                        ])
                    )))
                    continuation.finish()
                }
            }
            if streams == 2 {
                return AsyncThrowingStream { continuation in
                    continuation.yield(try! streamEvent(2, #"{"type":"turn_end","cost":{"totalUSD":2}}"#))
                    continuation.yield(try! streamEvent(3, #"{"type":"turn_end","cost":{"totalUSD":3}}"#))
                }
            }
            return AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            publishContinuation.finish()
        }
        var iterator = publishes.makeAsyncIterator()
        #expect(await iterator.next() == 100)
        #expect(await iterator.next() == 3)
        #expect(store.turns.first?.user?.text == "After restart")
        task.cancel()
        await task.value
    }

    @Test("Interrupted catch-up resumes its private candidate cursor")
    func interruptedCatchUpResumesCandidate() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        let pane = testPane()
        var snapshots = 0
        var requests: [String?] = []
        let (progress, progressContinuation) = AsyncStream<String>.makeStream()
        let (publishes, publishContinuation) = AsyncStream<Double>.makeStream()
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(cursor: "1", latest: "1", cost: 10)
                : try snapshot(cursor: "1", latest: "5", cost: 1)
        }
        store.publishObserver = { cost, _ in
            if let value = cost?.totalUSD { publishContinuation.yield(value) }
        }
        store.recoveryProgress = { cursor in
            if cursor == "3" { progressContinuation.yield("3") }
        }
        store.eventsProvider = { _, cursor in
            requests.append(cursor)
            switch requests.count {
            case 1:
                return AsyncThrowingStream { continuation in
                    continuation.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1", sessionID: "s1", cursor: "5",
                        event: .object([
                            "type": .string("stream.reset"),
                            "reason": .string("replay_gap")
                        ])
                    )))
                    continuation.finish()
                }
            case 2:
                return AsyncThrowingStream { continuation in
                    continuation.yield(try! streamEvent(2, #"{"type":"turn_end","cost":{"totalUSD":2}}"#))
                    continuation.yield(try! streamEvent(3, #"{"type":"turn_end","cost":{"totalUSD":3}}"#))
                    continuation.finish(throwing: APIError.streamEnded)
                }
            default:
                return AsyncThrowingStream { continuation in
                    continuation.yield(try! streamEvent(4, #"{"type":"turn_end","cost":{"totalUSD":4}}"#))
                    continuation.yield(try! streamEvent(5, #"{"type":"turn_end","cost":{"totalUSD":5}}"#))
                }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: pane)
        }
        defer {
            task.cancel()
            progressContinuation.finish()
            publishContinuation.finish()
        }
        var publishIterator = publishes.makeAsyncIterator()
        #expect(await publishIterator.next() == 10)
        var progressIterator = progress.makeAsyncIterator()
        #expect(await progressIterator.next() == "3")
        #expect(store.sessionCost?.totalUSD == 10)
        #expect(await publishIterator.next() == 5)
        #expect(requests.prefix(3).elementsEqual(["1", "1", "3"] as [String?]))
        #expect(snapshots == 2)
        task.cancel()
        await task.value
    }

    @Test("Legacy offline snapshot remains usable without opening a live stream")
    func legacyOfflineFallback() async throws {
        let store = PiConversationStore()
        var streamCalls = 0
        let (published, continuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in continuation.yield(()) }
        store.snapshotProvider = { _ in
            try JSONDecoder().decode(
                PiConversationSnapshot.self,
                from: Data(#"{"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","available":true,"connected":false,"session":{"id":"s1"},"state":{},"entries":[],"pending_interactions":[],"cursor":"1","oldest_cursor":"1","truncated":false}"#.utf8)
            )
        }
        store.eventsProvider = { _, _ in
            streamCalls += 1
            return AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer {
            task.cancel()
            continuation.finish()
        }
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()
        #expect(store.transport == .polling)
        #expect(store.connection == .bridgeOffline)
        #expect(store.turns.isEmpty)
        #expect(streamCalls == 0)
        task.cancel()
        await task.value
    }

    @Test("Same-shaped authoritative replacement refreshes prompt caches and revisions")
    func sameShapeReplacementRefreshesDerivedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.reconnectBackoffBase = .zero
        var snapshots = 0
        var streams = 0
        let (published, continuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in continuation.yield(()) }
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(sessionID: "old", cost: 4, prompt: "First prompt")
                : try snapshot(sessionID: "new", cost: 4, prompt: "Second prompt")
        }
        store.eventsProvider = { _, _ in
            streams += 1
            return streams == 1
                ? resetStream(reason: "session_changed", cursor: "2", sessionID: "old")
                : AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()
        let firstRevision = store.structureRevision
        _ = await iterator.next()
        #expect(store.turns.first?.user?.text == "Second prompt")
        #expect(store.lastUserMessage?.text == "Second prompt")
        #expect(store.userMessages.map(\.text) == ["Second prompt"])
        #expect(store.structureRevision > firstRevision)
        task.cancel()
        await task.value
    }

    @Test("Same-ID lineage reset commits without archiving a fake session")
    func sameSessionLineageResetCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.reconnectBackoffBase = .zero
        var snapshots = 0
        var streams = 0
        let (published, continuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in continuation.yield(()) }
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(sessionID: "same", cost: 1, prompt: "Before lineage reset")
                : try snapshot(sessionID: "same", cursor: "2", latest: "2", cost: 2, prompt: "After lineage reset")
        }
        store.eventsProvider = { _, _ in
            streams += 1
            return streams == 1
                ? resetStream(reason: "session_lineage_changed", cursor: "2", sessionID: "same")
                : AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = published.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        #expect(store.turns.first?.user?.text == "After lineage reset")
        #expect(store.sessionCost?.totalUSD == 2)
        #expect(store.sessionID == "same")
        #expect(store.closedSessions.isEmpty)
        task.cancel()
        await task.value
    }

    @Test("Older disconnected checkpoint cannot replace newer same-session progress")
    func offlineRollbackRetainsCommittedProjection() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        store.offlineSnapshotPollInterval = .seconds(60)
        var snapshots = 0
        var streams = 0
        let (fetched, continuation) = AsyncStream<Void>.makeStream()
        store.snapshotProvider = { _ in
            snapshots += 1
            if snapshots == 1 {
                return try snapshot(cursor: "5", latest: "5", cost: 5, prompt: "Newest")
            }
            continuation.yield(())
            return try snapshot(cursor: "2", latest: "2", cost: 2, prompt: "Stale", connected: false)
        }
        store.eventsProvider = { _, _ in
            streams += 1
            return streams == 1
                ? resetStream(reason: "replay_gap", cursor: "6")
                : AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = fetched.makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<20 where store.transport != .polling { await Task.yield() }
        #expect(store.turns.first?.user?.text == "Newest")
        #expect(store.sessionCost?.totalUSD == 5)
        #expect(store.connection == .bridgeOffline)
        #expect(store.transport == .polling)
        task.cancel()
        await task.value
    }

    @Test("Older legacy checkpoint without a watermark keeps newer committed progress")
    func legacyRollbackRetainsCommittedProjection() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var snapshots = 0
        var streams = 0
        let (requests, continuation) = AsyncStream<String?>.makeStream()
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(cursor: "5", latest: "5", cost: 5, prompt: "Newest")
                : try snapshot(cursor: "2", latest: nil, cost: 2, prompt: "Legacy stale")
        }
        store.eventsProvider = { _, cursor in
            streams += 1
            continuation.yield(cursor)
            return streams == 1
                ? resetStream(reason: "replay_gap", cursor: "6")
                : AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = requests.makeAsyncIterator()
        #expect(await iterator.next() == "5")
        #expect(await iterator.next() == "5")
        #expect(store.turns.first?.user?.text == "Newest")
        #expect(store.sessionCost?.totalUSD == 5)
        task.cancel()
        await task.value
    }

    @Test("Polling snapshot is generation-guarded across its fetch")
    func stalePollingFetchCannotPublishAfterReset() async throws {
        let store = PiConversationStore()
        store.offlineSnapshotPollInterval = .zero
        let gate = PiSnapshotGate()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var snapshots = 0
        store.snapshotProvider = { _ in
            snapshots += 1
            if snapshots == 1 {
                return try snapshot(prompt: "Committed", connected: false)
            }
            continuation.yield(())
            await gate.wait()
            return try snapshot(prompt: "Stale poll", connected: false)
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        store.reset()
        await gate.release()
        await Task.yield()
        #expect(store.turns.isEmpty)
        #expect(store.sessionCost == nil)
        task.cancel()
        continuation.finish()
        await task.value
    }

    @Test("Transport outages retry beyond the old lifetime budget and recover")
    func longTransportOutageRecovers() async throws {
        let store = PiConversationStore()
        store.reconnectAttemptLimit = 2
        store.reconnectBackoffBase = .zero
        let (requests, continuation) = AsyncStream<Int>.makeStream()
        var calls = 0
        var cursors: [String?] = []
        store.snapshotProvider = { _ in try snapshot() }
        store.eventsProvider = { _, cursor in
            calls += 1
            cursors.append(cursor)
            continuation.yield(calls)
            if calls <= 5 {
                return AsyncThrowingStream { $0.finish(throwing: APIError.streamEnded) }
            }
            if calls <= 10 {
                return AsyncThrowingStream { stream in
                    stream.yield(try! streamEvent(calls - 4, #"{"type":"turn_end","cost":{"totalUSD":\#(calls)}}"#))
                    stream.finish(throwing: APIError.streamEnded)
                }
            }
            return AsyncThrowingStream { _ in }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = requests.makeAsyncIterator()
        for expected in 1...11 { #expect(await iterator.next() == expected) }
        #expect(cursors == ["1", "1", "1", "1", "1", "1", "2", "3", "4", "5", "6"])
        task.cancel()
        await task.value
    }

    @Test("Silent candidate stream hits its no-progress deadline and is cancelled")
    func silentCandidateDeadlinePausesTruthfully() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        store.recoveryNoProgressTimeout = .milliseconds(5)
        var snapshots = 0
        var streams = 0
        let (terminated, terminationContinuation) = AsyncStream<Void>.makeStream()
        store.snapshotProvider = { _ in
            snapshots += 1
            return snapshots == 1
                ? try snapshot(cost: 10, prompt: "Committed")
                : try snapshot(cursor: "1", latest: "5", cost: 1, prompt: "Candidate")
        }
        store.eventsProvider = { _, _ in
            streams += 1
            if streams == 1 { return resetStream(reason: "replay_gap", cursor: "5") }
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in terminationContinuation.yield(()) }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer {
            task.cancel()
            terminationContinuation.finish()
        }
        var iterator = terminated.makeAsyncIterator()
        _ = await iterator.next()
        await task.value
        #expect(store.turns.first?.user?.text == "Committed")
        #expect(store.sessionCost?.totalUSD == 10)
        #expect(store.connection == .unavailable)
        #expect(store.lastError?.contains("Reopen") == true)
    }

    @Test("A stale candidate unwind cannot cancel a newer candidate deadline")
    func supersededCandidateKeepsNewDeadline() async throws {
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        store.recoveryNoProgressTimeout = .seconds(60)
        var snapshots = 0
        var streams = 0
        let (oldCandidateStarted, oldContinuation) = AsyncStream<Void>.makeStream()
        let (newCandidateStarted, newContinuation) = AsyncStream<Void>.makeStream()
        store.snapshotProvider = { _ in
            snapshots += 1
            switch snapshots {
            case 1: return try snapshot(cost: 10, prompt: "Committed")
            case 2: return try snapshot(cursor: "1", latest: "5", cost: 1, prompt: "Old candidate")
            default: return try snapshot(cursor: "1", latest: "6", cost: 2, prompt: "New candidate")
            }
        }
        store.eventsProvider = { _, _ in
            streams += 1
            switch streams {
            case 1:
                return resetStream(reason: "replay_gap", cursor: "5")
            case 2:
                return AsyncThrowingStream { _ in oldContinuation.yield(()) }
            case 3:
                store.recoveryNoProgressTimeout = .milliseconds(20)
                return resetStream(reason: "replay_gap", cursor: "6")
            default:
                return AsyncThrowingStream { _ in newContinuation.yield(()) }
            }
        }

        let first = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer {
            first.cancel()
            oldContinuation.finish()
            newContinuation.finish()
        }
        var oldIterator = oldCandidateStarted.makeAsyncIterator()
        _ = await oldIterator.next()
        let (secondFinished, secondFinishedContinuation) = AsyncStream<Void>.makeStream()
        let second = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
            secondFinishedContinuation.yield(())
            secondFinishedContinuation.finish()
        }
        defer {
            second.cancel()
            secondFinishedContinuation.finish()
        }
        var newIterator = newCandidateStarted.makeAsyncIterator()
        _ = await newIterator.next()
        var finishedIterator = secondFinished.makeAsyncIterator()
        _ = await finishedIterator.next()
        await second.value

        #expect(store.turns.first?.user?.text == "Committed")
        #expect(store.connection == .unavailable)
        #expect(store.lastError?.contains("Reopen") == true)
        first.cancel()
        await first.value
    }

    @Test("Transitional session and compaction checkpoints never publish")
    func resetBoundariesRejectTransitionalSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiConversationStore()
        store.sessionArchive = PiClosedSessionArchive(directory: root)
        store.reconnectBackoffBase = .zero
        var snapshots = 0
        var streams = 0
        var costs: [Double] = []
        let (published, continuation) = AsyncStream<Double>.makeStream()
        store.publishObserver = { cost, _ in
            if let value = cost?.totalUSD { costs.append(value); continuation.yield(value) }
        }
        store.snapshotProvider = { _ in
            snapshots += 1
            switch snapshots {
            case 1: return try snapshot(sessionID: "old", cursor: "5", latest: "5", cost: 10, prompt: "Original")
            case 2: return try snapshot(sessionID: "old", cursor: "7", latest: "7", cost: 1, prompt: "Pre compact")
            case 3: return try snapshot(sessionID: "old", cursor: "8", latest: "8", cost: 8, prompt: "Compacted")
            case 4: return try snapshot(sessionID: "old", cursor: "8", latest: "8", cost: 1, prompt: "Old session")
            default: return try snapshot(sessionID: "new", cursor: "1", latest: "1", cost: 2, prompt: "New session")
            }
        }
        store.eventsProvider = { _, _ in
            streams += 1
            switch streams {
            case 1:
                return AsyncThrowingStream { stream in
                    stream.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1", sessionID: "old", cursor: "8",
                        event: .object(["type": .string("session_compact")])
                    )))
                }
            case 2:
                return resetStream(reason: "session_changed", cursor: "9", sessionID: "old")
            default:
                return AsyncThrowingStream { _ in }
            }
        }

        let task = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())
        }
        defer { task.cancel(); continuation.finish() }
        var iterator = published.makeAsyncIterator()
        #expect(await iterator.next() == 10)
        #expect(await iterator.next() == 8)
        #expect(await iterator.next() == 2)
        #expect(costs == [10, 8, 2])
        #expect(store.turns.first?.user?.text == "New session")
        task.cancel()
        await task.value
    }

    @Test("Authentication failure is not retried as transport failure")
    func authenticationFailureStops() async {
        let store = PiConversationStore()
        var calls = 0
        store.snapshotProvider = { _ in
            calls += 1
            throw APIError.server(status: 401, message: "Unauthorized")
        }

        await store.follow(model: HerdrAppModel(arguments: []), pane: testPane())

        #expect(calls == 1)
        #expect(store.connection == .unavailable)
        #expect(store.lastError == "Unauthorized")
    }

    @Test("A superseded pane snapshot cannot overwrite the new pane")
    func stalePaneGenerationIsIgnored() async throws {
        let store = PiConversationStore()
        let gate = PiSnapshotGate()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (currentPublished, currentContinuation) = AsyncStream<Void>.makeStream()
        store.publishObserver = { _, _ in
            if store.turns.first?.user?.text == "Current" { currentContinuation.yield(()) }
        }
        store.snapshotProvider = { pane in
            if pane.paneID == "w1:p1" {
                startedContinuation.yield(())
                await gate.wait()
                return try snapshot(paneID: pane.paneID, prompt: "Stale")
            }
            return try snapshot(paneID: pane.paneID, prompt: "Current")
        }
        store.eventsProvider = { _, _ in AsyncThrowingStream { _ in } }

        let first = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane(id: "w1:p1"))
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        let second = Task { @MainActor in
            await store.follow(model: HerdrAppModel(arguments: []), pane: testPane(id: "w1:p2"))
        }

        var currentIterator = currentPublished.makeAsyncIterator()
        _ = await currentIterator.next()
        await gate.release()
        await Task.yield()
        #expect(store.turns.first?.user?.text == "Current")

        first.cancel()
        second.cancel()
        startedContinuation.finish()
        currentContinuation.finish()
        store.publishObserver = nil
        await first.value
        await second.value
    }

    private struct ToolState: Equatable {
        let id: String
        let status: PiToolInvocation.Status
    }

    private func toolStates(in store: PiConversationStore) -> [ToolState] {
        store.turns.flatMap(\.items).compactMap { item in
            guard case let .tool(tool) = item else { return nil }
            return ToolState(id: tool.callID, status: tool.status)
        }
    }

    private func testPane(id: String = "w1:p1") -> HerdrPane {
        HerdrPane(
            paneID: id, terminalID: id, workspaceID: "w1", tabID: "",
            focused: true, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
            label: nil, title: nil, agent: nil, displayAgent: nil, terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }

    private func resetStream(
        reason: String,
        cursor: String,
        sessionID: String = "s1"
    ) -> AsyncThrowingStream<PiConversationStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.envelope(PiConversationEnvelope(
                paneID: "w1:p1", sessionID: sessionID, cursor: cursor,
                event: .object([
                    "type": .string("stream.reset"),
                    "reason": .string(reason)
                ])
            )))
            continuation.finish()
        }
    }

    private func streamEvent(
        _ cursor: Int,
        _ event: String,
        sessionID: String = "s1"
    ) throws -> PiConversationStreamEvent {
        let value = try JSONDecoder().decode(PiJSONValue.self, from: Data(event.utf8))
        return .envelope(PiConversationEnvelope(
            paneID: "w1:p1", sessionID: sessionID, cursor: String(cursor), event: value
        ))
    }

    private func snapshot(
        paneID: String = "w1:p1",
        sessionID: String = "s1",
        cursor: String = "1",
        latest: String? = "1",
        cost: Double = 1,
        prompt: String = "Prompt",
        connected: Bool = true,
        toolCallID: String? = nil
    ) throws -> PiConversationSnapshot {
        let latestField = latest.map { ",\"latest_cursor\":\"\($0)\"" } ?? ""
        var entries: [String] = []
        if !prompt.isEmpty {
            entries.append(#"{"type":"message","id":"u1","message":{"role":"user","content":"\#(prompt)"}}"#)
        }
        if let toolCallID {
            entries.append(#"{"type":"message","id":"a-tool","message":{"role":"assistant","content":[{"type":"toolCall","id":"\#(toolCallID)","name":"read","arguments":{"path":"Synthetic.swift"}}]}}"#)
            entries.append(#"{"type":"message","id":"r-tool","message":{"role":"toolResult","toolCallId":"\#(toolCallID)","toolName":"read","isError":false,"content":[{"type":"text","text":"synthetic"}]}}"#)
        }
        let encodedEntries = "[\(entries.joined(separator: ","))]"
        return try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                #"{"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"\#(paneID)","available":true,"connected":\#(connected),"session":{"id":"\#(sessionID)"},"state":{"context":{"tokens":1},"cost":{"totalUSD":\#(cost),"totalTokens":10}},"entries":\#(encodedEntries),"pending_interactions":[],"cursor":"\#(cursor)"\#(latestField),"oldest_cursor":"1","truncated":false}"#.utf8
            )
        )
    }
}
