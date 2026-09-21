import Foundation
import Testing
@testable import herdr_harness_ios

@MainActor
@Suite("Car mode store")
struct CarModeStoreTests {
    // MARK: - Loading

    @Test("A refresh ranks the agents and writes each one-line status")
    func refreshDerivesSummaries() async throws {
        let model = try fixtureModel()
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            try SnapshotBuilder.snapshot(
                paneID: pane.paneID,
                connected: true,
                state: pane.agentStatus == .working
                    ? #"{"isStreaming":true}"#
                    : #"{"isStreaming":false}"#,
                entries: """
                [
                  {"type":"message","id":"e1","message":{"role":"user","content":[{"type":"text","text":"Export the example book list."}]}},
                  {"type":"message","id":"e2","message":{"role":"assistant","content":[{"type":"text","text":"The demo export is ready."}]}}
                ]
                """
            )
        }

        await store.refresh(model: model)

        #expect(store.loadPhase == .ready)
        #expect(store.lastRefreshedAt != nil)
        #expect(store.entries.map(\.id) == ["desktop|w1:p2", "desktop|w1:p1"])
        #expect(store.entries.first?.summary.kind == .question("Waiting for your answer."))
        #expect(store.entries.last?.summary.kind == .working)
        #expect(store.entries.allSatisfy { $0.loadedAt != nil })
    }

    @Test("One unreadable agent does not empty the others")
    func partialFailureKeepsTheRest() async throws {
        let model = try fixtureModel()
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            guard pane.paneID != "w1:p2" else { throw SnapshotBuilder.Failure.unreadable }
            return try SnapshotBuilder.snapshot(
                paneID: pane.paneID,
                connected: true,
                state: #"{"isStreaming":true}"#,
                entries: "[]"
            )
        }

        await store.refresh(model: model)

        #expect(store.loadPhase == .ready)
        #expect(store.entry(id: "desktop|w1:p1")?.summary.kind == .working)
        #expect(store.entry(id: "desktop|w1:p2")?.summary == .empty)
    }

    @Test("Refreshing reuses each agent's audio player so playback survives a reorder")
    func reorderKeepsPlayers() async throws {
        let model = try fixtureModel()
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            try SnapshotBuilder.snapshot(
                paneID: pane.paneID,
                connected: true,
                state: #"{"isStreaming":false}"#,
                entries: "[]"
            )
        }
        await store.refresh(model: model)
        let player = try #require(store.entry(id: "desktop|w1:p1")?.audioPlayer)

        // The blocked agent becomes idle, so it drops below the working one.
        try model.replaceStatus(of: "w1:p2", with: .idle)
        await store.refresh(model: model)

        #expect(store.entries.map(\.id) == ["desktop|w1:p1", "desktop|w1:p2"])
        #expect(store.entry(id: "desktop|w1:p1")?.audioPlayer === player)
    }

    @Test("An agent that leaves the fleet leaves Car mode, and the detail screen closes")
    func reconcileDropsDepartures() async throws {
        let model = try fixtureModel()
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            try SnapshotBuilder.snapshot(paneID: pane.paneID, connected: true, state: #"{"isStreaming":false}"#, entries: "[]")
        }
        await store.refresh(model: model)
        store.openDetail(for: "desktop|w1:p2")

        try model.removePane(id: "w1:p2")
        await store.refresh(model: model)

        #expect(store.entries.map(\.id) == ["desktop|w1:p1"])
        #expect(store.screen == .grid)
    }

    @Test("The count of agents follows the saved preference")
    func respectsAgentLimit() async throws {
        let model = try fixtureModel(paneCount: 6)
        var preferences = model.carModePreferences
        preferences.agentLimit = 2
        model.updateCarModePreferences(preferences)
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            try SnapshotBuilder.snapshot(paneID: pane.paneID, connected: true, state: #"{"isStreaming":true}"#, entries: "[]")
        }

        await store.refresh(model: model)

        #expect(store.entries.count == 2)
    }

    @Test("Demo mode uses the synthetic summaries instead of a server")
    func demoModeUsesFixtures() async throws {
        let model = try fixtureModel(paneCount: 3, demoVoice: true)
        model.workspaces = DemoData.workspaces
        let store = CarModeStore()
        store.demoSummaryProvider = { session in
            CarAgentSummary(
                kind: .answer("A synthetic demo answer."),
                response: "A synthetic demo answer.",
                asked: nil,
                phase: .idle,
                isBridgeConnected: true
            )
        }

        await store.refresh(model: model)

        #expect(store.loadPhase == .ready)
        #expect(!store.entries.isEmpty)
        #expect(store.entries.allSatisfy { $0.summary.kind == .answer("A synthetic demo answer.") })
        #expect(store.entries.allSatisfy { $0.connectionState == .demo })
    }

    // MARK: - Replies

    @Test("A spoken reply is confirmed before it is sent")
    func transcriptConfirmationFlow() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = voiceStore()
        await store.refresh(model: model)

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        #expect(store.voice.isRecording)
        #expect(store.voiceAgentID == "desktop|w1:p1")

        await store.finishVoice(model: model)
        #expect(store.voice == .review("Change the demo station to metric only."))

        await store.sendVoice(model: model)
        #expect(store.voice == .sent("Change the demo station to metric only.", .prompt))
        #expect(model.toastMessage != nil, "The terminal fallback reports what it sent")

        store.dismissSentConfirmation()
        #expect(store.voice == .idle)
        #expect(store.voiceAgentID == nil)
    }

    @Test("With confirmation off, a transcript is sent as soon as it is ready")
    func autoSend() async throws {
        let model = try fixtureModel(demoVoice: true)
        var preferences = model.carModePreferences
        preferences.confirmsVoiceTranscripts = false
        model.updateCarModePreferences(preferences)
        let store = voiceStore()
        await store.refresh(model: model)

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        await store.finishVoice(model: model)

        #expect(store.voice == .sent("Change the demo station to metric only.", .prompt))
    }

    @Test("The sent confirmation clears itself and returns to the grid")
    func sentConfirmationTimesOut() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = voiceStore()
        store.sentDisplayDuration = .milliseconds(30)
        await store.refresh(model: model)

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        await store.finishVoice(model: model)
        await store.sendVoice(model: model)
        #expect(store.voice != .idle)

        try await Task.sleep(for: .milliseconds(120))

        #expect(store.voice == .idle)
    }

    @Test("A failed transcription offers another attempt instead of a keyboard")
    func transcriptionFailure() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = CarModeStore()
        store.snapshotProvider = { pane in
            try SnapshotBuilder.snapshot(paneID: pane.paneID, connected: true, state: #"{"isStreaming":false}"#, entries: "[]")
        }
        store.captureOutcomeProvider = { .failure("No speech was found in the recording.") }

        await store.refresh(model: model)
        store.toggleVoice(for: "desktop|w1:p1", model: model)
        await store.finishVoice(model: model)

        #expect(store.voice == .failed("No speech was found in the recording."))
        #expect(store.isShowingVoiceLayer)

        store.retryVoice(model: model)
        #expect(store.voice.isRecording)
    }

    @Test("A tap that was too short is explained, not sent")
    func tooShortRecording() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = CarModeStore()
        store.captureOutcomeProvider = { .tooShort }

        await store.refresh(model: model)
        store.toggleVoice(for: "desktop|w1:p1", model: model)
        await store.finishVoice(model: model)

        guard case let .failed(message) = store.voice else {
            Issue.record("Expected a failure state, got \(store.voice)")
            return
        }
        #expect(message.contains("too short"))
    }

    @Test("Cancelling a recording drops the reply entirely")
    func cancelVoice() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = voiceStore()
        await store.refresh(model: model)

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        store.cancelVoice()

        #expect(store.voice == .idle)
        #expect(store.voiceAgentID == nil)
        #expect(!store.isShowingVoiceLayer)
    }

    @Test("A second tap on the recording agent finishes it, and another agent restarts")
    func tapToStartAndFinish() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = voiceStore()
        await store.refresh(model: model)

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        #expect(store.voice.isRecording)

        // The second tap schedules the finish; the state must move on promptly.
        store.toggleVoice(for: "desktop|w1:p1", model: model)
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.voice == .review("Change the demo station to metric only."))

        store.toggleVoice(for: "desktop|w1:p1", model: model)
        #expect(store.voice.isRecording)
        #expect(store.voiceAgentID == "desktop|w1:p1")
    }

    @Test("Voice capture is cancelled when Car mode goes away")
    func stopClearsCapture() async throws {
        let model = try fixtureModel(demoVoice: true)
        let store = voiceStore()
        await store.refresh(model: model)
        store.toggleVoice(for: "desktop|w1:p1", model: model)

        store.stop()

        #expect(store.voice == .idle)
    }

    // MARK: - Fixtures

    private func voiceStore() -> CarModeStore {
        let store = CarModeStore()
        store.captureOutcomeProvider = {
            .transcript(
                VoiceTranscription(
                    text: "Change the demo station to metric only.",
                    provider: .demo,
                    language: "en",
                    usedFallback: false
                )
            )
        }
        return store
    }

    private func fixtureModel(paneCount: Int = 2, demoVoice: Bool = false) throws -> HerdrAppModel {
        // A scratch defaults suite per fixture: Car mode preferences are shared
        // otherwise, and one test turning transcript confirmation off would
        // silently change another test's behavior.
        let suiteName = "herdr.carMode.store.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        // `demoVoice` keeps demo mode on, so `sendPrompt` completes without a
        // server; the loading tests turn it off to exercise snapshots.
        model.isDemoMode = demoVoice
        model.machines = [
            HerdrMachine(id: "desktop", name: "Studio", urlString: "https://desktop.example.invalid")
        ]
        model.machineStates = ["desktop": demoVoice ? .demo : .live]
        model.workspaces = [try Self.workspace(paneCount: paneCount)]
        return model
    }

    private static func workspace(paneCount: Int) throws -> HerdrWorkspace {
        let statuses = ["working", "blocked", "done", "idle", "working", "done"]
        let panes: [[String: Any]] = (0..<paneCount).map { index in
            [
                "pane_id": "w1:p\(index + 1)",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "agent": "Pi",
                "display_agent": "Pi",
                "title": "Fictional garden task \(index + 1)",
                "agent_status": statuses[index % statuses.count],
                "last_activity_at": ISO8601DateFormatter().string(
                    from: Date(timeIntervalSince1970: 1_900_000_000 + Double(index))
                ),
                // No `pi_semantic` here on purpose: the terminal fallback is the
                // path a voice reply takes when a bridge is unavailable.
                "cwd": "/tmp/herdr-demo",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "workspace_id": "w1",
            "label": "Garden Planner",
            "panes": panes,
        ])
        return try JSONDecoder().decode(HerdrWorkspace.self, from: data).stamped(machineID: "desktop")
    }
}
// MARK: - Snapshot fixtures

private enum SnapshotBuilder {
    enum Failure: Error {
        case unreadable
    }

    static func snapshot(
        paneID: String,
        connected: Bool,
        state: String,
        entries: String
    ) throws -> PiConversationSnapshot {
        let json = """
        {
          "protocol": {"name": "herdr.pi.semantic", "version": 1},
          "paneId": "\(paneID)",
          "available": true,
          "connected": \(connected),
          "state": \(state),
          "entries": \(entries),
          "pendingInteractions": [],
          "cursor": "1",
          "truncated": false
        }
        """
        return try JSONDecoder().decode(PiConversationSnapshot.self, from: Data(json.utf8))
    }
}

// MARK: - Mutable fleet fixture

private extension HerdrAppModel {
    func replaceStatus(of rawPaneID: String, with status: AgentStatus) throws {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.panes.contains { $0.paneID == rawPaneID }
        }) else { throw SnapshotBuilder.Failure.unreadable }
        var workspace = workspaces[workspaceIndex]
        guard let paneIndex = workspace.panes.firstIndex(where: { $0.paneID == rawPaneID }) else {
            throw SnapshotBuilder.Failure.unreadable
        }
        workspace.panes[paneIndex] = workspace.panes[paneIndex].withStatus(status)
        workspaces[workspaceIndex] = workspace
    }

    func removePane(id rawPaneID: String) throws {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.panes.contains { $0.paneID == rawPaneID }
        }) else { throw SnapshotBuilder.Failure.unreadable }
        var workspace = workspaces[workspaceIndex]
        workspace.panes.removeAll { $0.paneID == rawPaneID }
        workspaces[workspaceIndex] = workspace
    }
}

private extension HerdrPane {
    /// Rebuilds a pane with a different fleet status. `HerdrPane` is immutable
    /// so a fixture can model a status change the way the server would.
    func withStatus(_ status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: paneID,
            terminalID: terminalID,
            workspaceID: workspaceID,
            tabID: tabID,
            focused: focused,
            agentStatus: status,
            revision: revision + 1,
            cwd: cwd,
            foregroundCWD: foregroundCWD,
            label: label,
            title: title,
            agent: agent,
            displayAgent: displayAgent,
            terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitleStripped,
            stateLabels: stateLabels,
            tokens: tokens,
            piSemantic: piSemantic,
            firstSeenAt: firstSeenAt,
            lastActivityAt: lastActivityAt,
            workingSince: workingSince,
            reservedShell: reservedShell
        ).stamped(machineID: machineID)
    }
}
