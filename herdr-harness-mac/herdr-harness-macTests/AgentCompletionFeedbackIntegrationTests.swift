import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Agent completion feedback integration", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AgentCompletionFeedbackIntegrationTests {
    // MARK: Pi conversation lifecycle

    @Test("Committed settlement plays once and shares its receipt with the fleet")
    func committedSettlementDeduplicatesFleet() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let pane = Self.testPane()

        // A successful refresh first: the previous idle answer is the baseline.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "idle", lastActivityAt: "2030-01-01T00:00:00Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 0)

        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var eventsContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in try Self.snapshot(prompt: "Earlier answer") }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in eventsContinuation = continuation }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: pane)
        }
        defer {
            follow.cancel()
            eventsContinuation?.finish()
        }

        try await Self.waitUntil { store.sessionID == "s1" && !store.turns.isEmpty }
        #expect(recorder.count == 0)

        // Submitting and starting work is silent.
        eventsContinuation?.yield(try Self.streamEvent(2, #"{"type":"agent_start"}"#))
        try await Self.waitUntil { store.phase == .working }
        #expect(recorder.count == 0)

        // Committed settlement plays exactly once.
        eventsContinuation?.yield(try Self.streamEvent(3, #"{"type":"agent_settled"}"#))
        try await Self.waitUntil { recorder.count == 1 }

        // The fleet observes work starting for the same run. That working
        // transition makes the later done refresh independently able to claim
        // a completion, so this exercises the shared receipt rather than a
        // refresh that could never play on its own.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:04Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        // The fleet observes the same completion; the committed settlement
        // receipt consumes the transition instead of playing again.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:05Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        // A later turn is independently eligible.
        eventsContinuation?.yield(try Self.streamEvent(4, #"{"type":"agent_start"}"#))
        try await Self.waitUntil { store.phase == .working }
        eventsContinuation?.yield(try Self.streamEvent(5, #"{"type":"agent_settled"}"#))
        try await Self.waitUntil { recorder.count == 2 }

        follow.cancel()
        eventsContinuation?.finish()
        await follow.value
    }

    @Test("Cancellation and failure never play the completion cue")
    func cancellationAndFailureAreSilent() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var eventsContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in try Self.snapshot(prompt: "Earlier answer") }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in eventsContinuation = continuation }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: Self.testPane())
        }
        defer {
            follow.cancel()
            eventsContinuation?.finish()
        }

        try await Self.waitUntil { store.sessionID == "s1" }
        eventsContinuation?.yield(try Self.streamEvent(2, #"{"type":"agent_start"}"#))
        try await Self.waitUntil { store.phase == .working }
        eventsContinuation?.yield(try Self.streamEvent(
            3,
            #"{"type":"message_end","message":{"role":"assistant","stopReason":"aborted","content":[{"type":"text","text":"Stopped"}]}}"#
        ))
        try await Self.waitUntil { store.phase == .failed }
        eventsContinuation?.yield(try Self.streamEvent(4, #"{"type":"agent_settled"}"#))
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.count == 0)

        // A reported error is a failure outcome, not a completion.
        eventsContinuation?.yield(try Self.streamEvent(5, #"{"type":"agent_start"}"#))
        try await Self.waitUntil { store.phase == .working }
        eventsContinuation?.yield(try Self.streamEvent(6, #"{"type":"error","message":"Synthetic failure"}"#))
        try await Self.waitUntil { store.phase == .failed }
        #expect(recorder.count == 0)

        follow.cancel()
        eventsContinuation?.finish()
        await follow.value
    }

    @Test("Private recovery replay is silent; the next committed settlement plays once")
    func privateRecoveryReplayIsSilent() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var snapshotCalls = 0
        var streamRequests = 0
        var catchUpContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        var liveContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in
            snapshotCalls += 1
            if snapshotCalls == 1 {
                return try Self.snapshot(cursor: "1", latest: "1", prompt: "Earlier answer")
            }
            // Recovery snapshot: the same session, work in flight, a watermark
            // the candidate must replay up to before it can commit.
            return try Self.snapshot(cursor: "1", latest: "5", working: true, prompt: "Earlier answer")
        }
        store.eventsProvider = { _, _ in
            streamRequests += 1
            switch streamRequests {
            case 1:
                return AsyncThrowingStream { continuation in
                    continuation.yield(.envelope(PiConversationEnvelope(
                        paneID: "w1:p1",
                        sessionID: "s1",
                        cursor: "2",
                        event: .object([
                            "type": .string("stream.reset"),
                            "reason": .string("replay_gap")
                        ])
                    )))
                    continuation.finish()
                }
            case 2:
                return AsyncThrowingStream { continuation in catchUpContinuation = continuation }
            default:
                return AsyncThrowingStream { continuation in liveContinuation = continuation }
            }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: Self.testPane())
        }
        defer {
            follow.cancel()
            catchUpContinuation?.finish()
            liveContinuation?.finish()
        }

        try await Self.waitUntil { streamRequests == 2 }
        // Replay a settlement into the private candidate and reach the
        // watermark, which commits the candidate.
        catchUpContinuation?.yield(try Self.streamEvent(5, #"{"type":"agent_settled"}"#))
        try await Self.waitUntil { streamRequests == 3 }
        #expect(recorder.count == 0)

        liveContinuation?.yield(try Self.streamEvent(6, #"{"type":"agent_start"}"#))
        try await Self.waitUntil { store.phase == .working }
        liveContinuation?.yield(try Self.streamEvent(7, #"{"type":"agent_settled"}"#))
        try await Self.waitUntil { recorder.count == 1 }

        follow.cancel()
        catchUpContinuation?.finish()
        liveContinuation?.finish()
        await follow.value
    }

    // MARK: Fleet-only ownership

    @Test("A successful fleet refresh owns completion for unmounted chats")
    func fleetRefreshCompletion() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let client = fixture.fleetClient()
        let generation = fixture.model.connectionGeneration

        // Startup baseline with an idle pane.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "idle", lastActivityAt: "2030-01-01T00:00:00Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 0)

        // Starting work is silent.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:01Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 0)

        // The working → done transition plays once.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:02Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)

        // Repeated refreshes of the same done episode stay silent.
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)

        // A later turn plays its own single cue.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:03Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:04Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 2)
    }

    @Test("A completion alert covers a run that finished before a running poll")
    func fleetCompletionAlertCoversFastRun() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let client = fixture.fleetClient()
        let generation = fixture.model.connectionGeneration

        let baselineAlert = Self.alertJSON(id: "a1", status: "done")
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(
                paneStatus: "done",
                lastActivityAt: "2030-01-01T00:00:00Z",
                alerts: [baselineAlert]
            )
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 0)

        // No working poll is observed; only the new alert proves the finish.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(
                paneStatus: "done",
                lastActivityAt: "2030-01-01T00:00:01Z",
                alerts: [baselineAlert, Self.alertJSON(id: "a2", status: "done")]
            )
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)

        // The same alert and episode repeated never play again.
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)
    }

    @Test("A fleet alert published before its done transition shares one receipt")
    func fleetAlertBeforeDoneTransitionSharesReceipt() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let client = fixture.fleetClient()
        let generation = fixture.model.connectionGeneration

        // Baseline idle.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "idle", lastActivityAt: "2030-01-01T00:00:00Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 0)

        // Work starts.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:01Z", alerts: [])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 0)

        // The server publishes the alert before the debounced snapshot reports
        // the done transition, so the cached pane still reads working.
        let doneAlert = Self.alertJSON(id: "a1", status: "done", createdAt: "2030-01-01T00:00:02Z")
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:01Z", alerts: [doneAlert])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)

        // The following done transition is the same completion, not a new one.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:02Z", alerts: [doneAlert])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 1)

        // A genuinely later turn plays its own single cue.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:01:00Z", alerts: [doneAlert])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:01:05Z", alerts: [doneAlert])
        }
        try await fixture.model.refresh(machineID: fixture.machine.id, using: client, expectedGeneration: generation)
        #expect(recorder.count == 2)
    }

    @Test("A fleet-first receipt survives a delayed Pi start and settlement replay")
    func fleetFirstReceiptSurvivesDelayedPiReplay() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let pane = Self.testPane()

        // Baseline idle.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "idle", lastActivityAt: "2030-01-01T00:00:00Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 0)

        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var eventsContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in try Self.snapshot(prompt: "Earlier answer") }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in eventsContinuation = continuation }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: pane)
        }
        defer {
            follow.cancel()
            eventsContinuation?.finish()
        }

        try await Self.waitUntil { store.sessionID == "s1" && !store.turns.isEmpty }
        #expect(recorder.count == 0)

        // The fleet observes the whole run while the stream is disconnected.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:01Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 0)
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:10Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        // The committed stream resumes and replays the same turn. Both events
        // predate the fleet completion, so the existing receipt stays single.
        eventsContinuation?.yield(try Self.streamEvent(
            2,
            #"{"type":"agent_start"}"#,
            generatedAt: "2030-01-01T00:00:05Z"
        ))
        eventsContinuation?.yield(try Self.streamEvent(
            3,
            #"{"type":"agent_settled"}"#,
            generatedAt: "2030-01-01T00:00:06Z"
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.count == 1)

        // A genuinely later turn is newer than the receipt and plays once.
        eventsContinuation?.yield(try Self.streamEvent(
            4,
            #"{"type":"agent_start"}"#,
            generatedAt: "2030-01-01T00:01:00Z"
        ))
        try await Self.waitUntil { store.phase == .working }
        eventsContinuation?.yield(try Self.streamEvent(
            5,
            #"{"type":"agent_settled"}"#,
            generatedAt: "2030-01-01T00:01:05Z"
        ))
        try await Self.waitUntil { recorder.count == 2 }

        follow.cancel()
        eventsContinuation?.finish()
        await follow.value
    }

    @Test("A fresh alert over a stale done pane keeps one cue for the raced completion")
    func freshAlertOverStaleDonePaneKeepsReceiptInstant() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let pane = Self.testPane()

        // Baseline: the previous answer is done at T0 and its alert is known.
        let baselineAlert = Self.alertJSON(id: "a1", status: "done", createdAt: "2030-01-01T00:00:00Z")
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(
                paneStatus: "done",
                lastActivityAt: "2030-01-01T00:00:00Z",
                alerts: [baselineAlert]
            )
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 0)

        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var eventsContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in try Self.snapshot(prompt: "Earlier answer") }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in eventsContinuation = continuation }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: pane)
        }
        defer {
            follow.cancel()
            eventsContinuation?.finish()
        }
        try await Self.waitUntil { store.sessionID == "s1" && !store.turns.isEmpty }
        #expect(recorder.count == 0)

        // The server publishes the new completion's alert at T2, but the
        // debounced pane snapshot still reports the previous done episode T0.
        let freshAlert = Self.alertJSON(id: "a2", status: "done", createdAt: "2030-01-01T00:00:20Z")
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(
                paneStatus: "done",
                lastActivityAt: "2030-01-01T00:00:00Z",
                alerts: [baselineAlert, freshAlert]
            )
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        // The committed stream resumes late: the delayed start at T1 predates
        // the receipted completion T2, so the settlement of that same run is
        // the already-receipted completion and stays silent.
        eventsContinuation?.yield(try Self.streamEvent(
            2,
            #"{"type":"agent_start"}"#,
            generatedAt: "2030-01-01T00:00:10Z"
        ))
        try await Task.sleep(for: .milliseconds(30))
        eventsContinuation?.yield(try Self.streamEvent(
            3,
            #"{"type":"agent_settled"}"#,
            generatedAt: "2030-01-01T00:00:30Z"
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.count == 1)

        // A genuinely later turn plays its own single cue.
        eventsContinuation?.yield(try Self.streamEvent(
            4,
            #"{"type":"agent_start"}"#,
            generatedAt: "2030-01-01T00:01:00Z"
        ))
        try await Self.waitUntil { store.phase == .working }
        eventsContinuation?.yield(try Self.streamEvent(
            5,
            #"{"type":"agent_settled"}"#,
            generatedAt: "2030-01-01T00:01:05Z"
        ))
        try await Self.waitUntil { recorder.count == 2 }
        // The later turn's single cue is not followed by a delayed duplicate.
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.count == 2)

        follow.cancel()
        eventsContinuation?.finish()
        await follow.value
    }

    @Test("A delayed fleet alert never completes a newer Pi turn")
    func delayedFleetAlertDoesNotCompleteNewPiTurn() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        let pane = Self.testPane()

        // Baseline idle.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "idle", lastActivityAt: "2030-01-01T00:00:00Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )

        let store = PiConversationStore()
        store.reconnectBackoffBase = .zero
        var eventsContinuation: AsyncThrowingStream<PiConversationStreamEvent, any Error>.Continuation?
        store.snapshotProvider = { _ in try Self.snapshot(prompt: "Earlier answer") }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in eventsContinuation = continuation }
        }
        let follow = Task { @MainActor in
            await store.follow(model: fixture.model, pane: pane)
        }
        defer {
            follow.cancel()
            eventsContinuation?.finish()
        }
        try await Self.waitUntil { store.sessionID == "s1" && !store.turns.isEmpty }

        // The fleet observes turn one start and finish; that receipt plays.
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:00:01Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "done", lastActivityAt: "2030-01-01T00:00:10Z", alerts: [])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        // A new turn starts before the previous completion's alert arrives.
        eventsContinuation?.yield(try Self.streamEvent(
            2,
            #"{"type":"agent_start"}"#,
            generatedAt: "2030-01-01T00:01:00Z"
        ))
        try await Self.waitUntil { store.phase == .working }

        // The delayed alert for turn one must not complete or play for the new
        // turn, and must not suppress its eventual settlement.
        let delayedAlert = Self.alertJSON(id: "a1", status: "done", createdAt: "2030-01-01T00:00:10Z")
        CompletionFleetURLProtocol.state.withLock {
            $0 = CompletionFleetProtocolState(paneStatus: "working", lastActivityAt: "2030-01-01T00:01:00Z", alerts: [delayedAlert])
        }
        try await fixture.model.refresh(
            machineID: fixture.machine.id,
            using: fixture.fleetClient(),
            expectedGeneration: fixture.model.connectionGeneration
        )
        #expect(recorder.count == 1)

        eventsContinuation?.yield(try Self.streamEvent(
            3,
            #"{"type":"agent_settled"}"#,
            generatedAt: "2030-01-01T00:01:05Z"
        ))
        try await Self.waitUntil { recorder.count == 2 }

        follow.cancel()
        eventsContinuation?.finish()
        await follow.value
    }

    // MARK: User-facing headless runs

    @Test("A user-facing run plays once when its poll observes completion")
    func headlessRunPlaysOnce() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        CompletionRunURLProtocol.state.withLock { $0 = CompletionRunProtocolState(status: "running") }
        let controller = HeadlessAgentController(reportsCompletionFeedback: true)
        controller.pollingInterval = .milliseconds(2)
        controller.pollingRetryInterval = .milliseconds(2)

        await controller.submit(prompt: "Synthetic prompt", machineID: fixture.machine.id, model: fixture.model)
        #expect(controller.run?.status == .running)
        #expect(recorder.count == 0)

        CompletionRunURLProtocol.state.withLock { $0.status = "completed" }
        try await Self.waitUntil { recorder.count == 1 }
        #expect(controller.run?.status == .completed)

        // A repeated terminal observation and a later promotion never replay.
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.count == 1)
    }

    @Test("Opening completed history is silent; a restored active run plays once")
    func restoredRuns() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        CompletionRunURLProtocol.state.withLock { $0 = CompletionRunProtocolState(status: "completed") }
        let controller = HeadlessAgentController(reportsCompletionFeedback: true)
        controller.pollingInterval = .milliseconds(2)
        controller.pollingRetryInterval = .milliseconds(2)

        // Opening an already-finished run is history, not news.
        controller.observe(
            Self.headlessRun(id: "run-history", status: .completed),
            machineID: fixture.machine.id,
            model: fixture.model
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.count == 0)

        // A restored active run is armed; its completion plays once.
        CompletionRunURLProtocol.state.withLock { $0.status = "running" }
        controller.observe(
            Self.headlessRun(id: "run-restored", status: .running),
            machineID: fixture.machine.id,
            model: fixture.model
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.count == 0)

        CompletionRunURLProtocol.state.withLock { $0.status = "completed" }
        try await Self.waitUntil { recorder.count == 1 }
    }

    @Test("A run that finishes before the first running poll still plays once")
    func fastRunPlaysOnce() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        CompletionRunURLProtocol.state.withLock { $0 = CompletionRunProtocolState(status: "completed") }
        let controller = HeadlessAgentController(reportsCompletionFeedback: true)
        controller.pollingInterval = .milliseconds(2)

        await controller.submit(prompt: "Synthetic prompt", machineID: fixture.machine.id, model: fixture.model)
        #expect(controller.run?.status == .completed)
        try await Self.waitUntil { recorder.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.count == 1)
    }

    @Test("Internal summary work never plays the completion cue")
    func internalRunsAreSilent() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let recorder = CompletionFeedbackRecorder()
        fixture.model.agentCompletionFeedback.playback = { recorder.record() }
        CompletionRunURLProtocol.state.withLock { $0 = CompletionRunProtocolState(status: "running") }
        let controller = HeadlessAgentController()
        controller.pollingInterval = .milliseconds(2)

        await controller.submit(prompt: "Synthetic summary", machineID: fixture.machine.id, model: fixture.model)
        CompletionRunURLProtocol.state.withLock { $0.status = "completed" }
        try await Task.sleep(for: .milliseconds(60))
        #expect(recorder.count == 0)
    }

    // MARK: Helpers

    private static func testPane() -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1",
            terminalID: "terminal-1",
            workspaceID: "w1",
            tabID: "",
            focused: true,
            agentStatus: .idle,
            revision: 1,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        ).stamped(machineID: "m1")
    }

    private static func headlessRun(id: String, status: HeadlessAgentRunStatus) -> HeadlessAgentRun {
        HeadlessAgentRun(
            id: id,
            status: status,
            mode: .ask,
            model: nil,
            thinkingLevel: nil,
            prompt: "Synthetic prompt",
            cwd: nil,
            response: status == .completed ? "Synthetic answer" : nil,
            error: nil,
            createdAt: "2030-01-01T00:00:00Z",
            startedAt: "2030-01-01T00:00:00Z",
            finishedAt: status.isTerminal ? "2030-01-01T00:00:01Z" : nil,
            sessionID: nil,
            sessionFile: nil,
            costUSD: nil,
            promotedWorkspaceID: nil,
            promotedPaneID: nil,
            attachments: nil,
            steps: nil,
            stepsTruncated: nil,
            threadRootRunId: nil
        )
    }

    private static func streamEvent(
        _ cursor: Int,
        _ event: String,
        sessionID: String = "s1",
        generatedAt: String? = nil
    ) throws -> PiConversationStreamEvent {
        let value = try JSONDecoder().decode(PiJSONValue.self, from: Data(event.utf8))
        return .envelope(PiConversationEnvelope(
            paneID: "w1:p1",
            sessionID: sessionID,
            cursor: String(cursor),
            event: value,
            generatedAt: generatedAt
        ))
    }

    private static func snapshot(
        cursor: String = "1",
        latest: String? = "1",
        working: Bool = false,
        prompt: String = "Earlier answer"
    ) throws -> PiConversationSnapshot {
        let latestField = latest.map { ",\"latest_cursor\":\"\($0)\"" } ?? ""
        let entries = prompt.isEmpty
            ? ""
            : #"{"type":"message","id":"u1","message":{"role":"user","content":"\#(prompt)"}}"#
        return try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                #"{"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","available":true,"connected":true,"session":{"id":"s1"},"state":{"context":{"tokens":1},"cost":{"totalUSD":1,"totalTokens":10},"isStreaming":\#(working)},"entries":[\#(entries)],"pending_interactions":[],"cursor":"\#(cursor)"\#(latestField),"oldest_cursor":"0","truncated":false}"#.utf8
            )
        )
    }

    private static func alertJSON(
        id: String,
        status: String,
        createdAt: String = "2030-01-01T00:00:00Z"
    ) -> String {
        #"{"id":"\#(id)","workspace_id":"w1","pane_id":"w1:p1","status":"\#(status)","title":"Ready","message":"","created_at":"\#(createdAt)","is_read":true}"#
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for condition")
    }
}

/// One isolated Mac app model backed by synthetic URLProtocol servers.
@MainActor
private struct ModelFixture {
    let suite: String
    let model: HerdrAppModel
    let machine: HerdrMachine
    private let defaults: UserDefaults
    private let fleetSession: URLSession
    private let runSession: URLSession

    init() throws {
        suite = "agent-completion-feedback-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let fleetConfiguration = URLSessionConfiguration.ephemeral
        fleetConfiguration.protocolClasses = [CompletionFleetURLProtocol.self]
        let fleetSessionValue = URLSession(configuration: fleetConfiguration)
        fleetSession = fleetSessionValue
        let runConfiguration = URLSessionConfiguration.ephemeral
        runConfiguration.protocolClasses = [CompletionRunURLProtocol.self]
        let runSessionValue = URLSession(configuration: runConfiguration)
        runSession = runSessionValue

        let credentials = TestCredentialStore()
        machine = HerdrMachine(id: "m1", name: "Machine", urlString: "http://localhost:9092")
        credentials.set("test", for: "api-token.\(machine.id)")
        model = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { configuration in
            HerdrAPIClient(configuration: configuration, session: runSessionValue)
        }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
    }

    func fleetClient() -> HerdrAPIClient {
        let configuration = ServerConfiguration(urlString: machine.urlString, token: "test")!
        return HerdrAPIClient(configuration: configuration, session: fleetSession)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct CompletionFleetProtocolState: Sendable {
    var paneStatus: String
    var lastActivityAt: String
    var alerts: [String]
}

private final class CompletionFleetURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex(CompletionFleetProtocolState(
        paneStatus: "idle",
        lastActivityAt: "2030-01-01T00:00:00Z",
        alerts: []
    ))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.path == "/api/v1/workspaces" {
            let served = Self.state.withLock { $0 }
            let alerts = served.alerts.joined(separator: ",")
            data = Data(
                """
                {"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":0,"active_tab_id":"","agent_status":"\(served.paneStatus)","panes":[{"pane_id":"w1:p1","terminal_id":"terminal-1","workspace_id":"w1","tab_id":"","focused":true,"agent_status":"\(served.paneStatus)","revision":1,"last_activity_at":"\(served.lastActivityAt)"}]}],"alerts":[\(alerts)]}
                """.utf8
            )
        } else {
            data = Data(#"{"ok":true}"#.utf8)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct CompletionRunProtocolState: Sendable {
    var status: String
}

private final class CompletionRunURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex(CompletionRunProtocolState(status: "running"))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let status = Self.state.withLock { $0.status }
        let isStart = url.path == "/api/v1/agent-runs" && request.httpMethod == "POST"
        let runID = isStart ? "run-1" : url.lastPathComponent
        var run: [String: Any] = [
            "id": runID,
            "status": status,
            "prompt": "Synthetic prompt",
            "createdAt": "2030-01-01T00:00:00Z",
        ]
        if status == "completed" {
            run["response"] = "Synthetic answer"
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "run": run])) ?? Data()
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
