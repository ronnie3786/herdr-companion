import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi response attachments")
struct PiResponseArtifactsTests {
    @Test("New results follow the producing tool, even when later responses exist")
    func toolIdentityAssociatesExactResponse() {
        let artifact = artifact(id: "report", callID: "call-first")
        let turns = [turn("first", callID: "call-first"), turn("second", callID: "call-second")]
        let projection = project([artifact], turns: turns)
        #expect(projection.byTurnID["first"] == [artifact])
        #expect(projection.byTurnID["second"] == nil)
        #expect(projection.unassociated.isEmpty)
        let rows = PiTimelineRow.rows(for: turns, artifactsByTurnID: projection.byTurnID)
        let artifactIndex = rows.firstIndex { if case .artifacts = $0.content { return true }; return false }
        let secondIndex = rows.firstIndex { $0.turnID == "second" }
        #expect(artifactIndex != nil && secondIndex != nil && artifactIndex! < secondIndex!)
        #expect(artifactIndex! + 1 == secondIndex!)
    }

    @Test("Saved tool details restore cards when an old file is absent from the server list")
    func savedSnapshotRestoresHistoricalArtifact() throws {
        let snapshot = try JSONDecoder().decode(PiConversationSnapshot.self, from: Data("""
        {"session":{"id":"session-1"},"entries":[
          {"type":"message","id":"u1","message":{"role":"user","content":"Create a report"}},
          {"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"present_result","arguments":{}}]}},
          {"type":"message","id":"t1","message":{"role":"toolResult","toolCallId":"call-1","toolName":"present_result","content":[{"type":"text","text":"Ready"}],"details":{"artifact":{
            "id":"art_expired","originType":"pane","originId":"p1","sessionId":"session-1","kind":"file","title":"Quarterly report","filename":"report.pdf","byteSize":10,"downloadPath":"/api/v1/result-artifacts/art_expired/content","createdAt":"2026-09-01T10:00:00Z"
          }}}},
          {"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Here is the report."}]}},
          {"type":"message","id":"u2","message":{"role":"user","content":"Another question"}}
        ]}
        """.utf8))
        var reducer = PiConversationReducer()
        reducer.replace(with: snapshot)
        let projection = project([], turns: reducer.turns)
        let restored = try #require(projection.byTurnID["turn:u1"]?.first)
        #expect(restored.rawID == "art_expired")
        #expect(restored.machineID == "work")
        #expect(restored.displayTitle == "Quarterly report")
        #expect(projection.byTurnID["turn:u2"] == nil)
    }

    @Test("Live tool details and replay produce the same durable result card")
    func liveToolResultPersistsMetadata() throws {
        var reducer = PiConversationReducer()
        let event = try JSONDecoder().decode(PiJSONValue.self, from: Data("""
        {"type":"tool_execution_end","toolCallId":"call-live","toolName":"present_result","result":{"content":[{"type":"text","text":"Ready"}],"details":{"artifact":{
          "id":"art_live","originType":"pane","originId":"p1","sessionId":"session-1","kind":"link","title":"Design","url":"https://example.com/design","createdAt":"2026-09-01T10:00:00Z"
        }}}}
        """.utf8))
        _ = reducer.apply(PiConversationEnvelope(paneID: "p1", sessionID: "session-1", cursor: "1", event: event))
        let projection = project([], turns: reducer.turns)
        #expect(projection.byTurnID.values.flatMap { $0 }.map(\.rawID) == ["art_live"])
    }

    @Test("Legacy results with no response proof stay explicitly unassociated")
    func doesNotGuessByTimestamp() {
        let legacy = artifact(id: "legacy", callID: nil)
        let projection = project([legacy], turns: [turn("newest", callID: "call-newest")])
        #expect(projection.byTurnID.isEmpty)
        #expect(projection.unassociated == [legacy])
    }

    @Test("Canonical metadata wins and saved details do not duplicate the same card")
    func canonicalWinsAndDeduplicates() {
        let saved = artifact(id: "same", callID: nil, title: "Saved title")
        let canonical = artifact(id: "same", callID: "call-1", title: "Current title")
        let projection = project([canonical], turns: [turn("first", callID: "call-1", saved: saved)])
        #expect(projection.byTurnID["first"] == [canonical])
        #expect(projection.unassociated.isEmpty)
    }

    @Test("A reused pane hides old sessions and a promoted run follows its Pi session")
    func sessionScopeAndPromotion() throws {
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data("""
        {"pane_id":"p1","workspace_id":"w1","tab_id":"t1","agent_status":"idle","revision":1}
        """.utf8)).stamped(machineID: "work")
        let old = artifact(id: "old", callID: nil, sessionID: "session-old")
        let current = artifact(id: "current", callID: nil)
        let promoted = AgentResultArtifact(
            id: "promoted", originType: .agentRun, originID: "agr_123",
            sessionID: "session-1", kind: .link, title: "Promoted result",
            createdAt: "2026-09-01T10:00:00Z", url: URL(string: "https://example.com")
        ).stamped(machineID: "work")
        let otherMachine = current.stamped(machineID: "home")
        let matching = PaneResultArtifacts.matching([old, current, promoted, otherMachine], pane: pane, sessionID: "session-1")
        #expect(Set(matching.map(\.rawID)) == ["current", "promoted"])
    }

    @Test("Reading the displayed transcript uses its session identity before pane metadata refreshes")
    @MainActor
    func displayedSessionControlsReadAcknowledgement() throws {
        let suiteName = "PiResponseArtifactsTests.sessionRead.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data("""
        {"pane_id":"p1","workspace_id":"w1","tab_id":"t1","agent_status":"idle","revision":1,
         "pi_semantic":{"sessionId":"session-old","available":true,"connected":true,"protocolVersion":1}}
        """.utf8)).stamped(machineID: "work")
        let old = artifact(id: "old", callID: nil, sessionID: "session-old")
        let visible = artifact(id: "visible", callID: nil)
        model.ingestResultArtifacts([old, visible], machineID: "work", replacingMachineSlice: true)

        model.markPaneResultArtifactsRead(pane, sessionID: "session-1")

        #expect(model.resultArtifactPhase(id: old.id) == .available)
        #expect(model.resultArtifactPhase(id: visible.id) == .opened)
        #expect(model.resultArtifacts.count == 2)
    }

    @Test("Invalid saved metadata cannot become an openable chat attachment")
    func invalidSavedMetadataIsIgnored() {
        #expect(AgentResultArtifact(piMetadata: .object([
            "id": .string("bad"), "originType": .string("pane"), "originId": .string("p1"),
            "kind": .string("link"), "url": .string("file:///etc/passwd")
        ])) == nil)
    }

    private func project(_ artifacts: [AgentResultArtifact], turns: [PiConversationTurn]) -> PiResponseArtifacts {
        PiResponseArtifacts(artifacts: artifacts, turns: turns, machineID: "work", sessionID: "session-1")
    }

    private func turn(_ id: String, callID: String, saved: AgentResultArtifact? = nil) -> PiConversationTurn {
        PiConversationTurn(id: id, user: PiUserMessage(id: "user-\(id)", text: id), items: [
            .tool(PiToolInvocation(
                id: "tool:\(callID)", callID: callID, name: "present_result", arguments: nil, result: nil,
                status: .succeeded, startedAt: nil, finishedAt: nil, resultArtifact: saved
            )),
            .assistant(PiAssistantBlock(id: "answer-\(id)", text: "Ready", status: .complete))
        ], isActive: false)
    }

    private func artifact(
        id: String, callID: String?, sessionID: String = "session-1", title: String = "Report"
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id, originType: .pane, originID: "p1", sessionID: sessionID, toolCallID: callID,
            kind: .link, title: title, createdAt: "2026-09-01T10:00:00Z", url: URL(string: "https://example.com/report")
        ).stamped(machineID: "work")
    }
}
