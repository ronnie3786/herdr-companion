import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import herdr_harness_mac

@Suite("Conversation context", .serialized)
struct ConversationContextTests {
    @Test("The app-internal drag reference has a stable Codable round trip")
    func transferRoundTrip() throws {
        let original = ConversationContextTransfer(
            sourcePaneID: "machine-a|w1:p2",
            expectedSessionID: "session-example",
            title: "Review the parser",
            agent: "Pi",
            path: "/synthetic/project"
        )

        let decoded = try JSONDecoder().decode(
            ConversationContextTransfer.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
        #expect(UTType.herdrPiChatReference.identifier == "dev.herdr.companion.pi-chat-reference")
    }

    @Test("Capture validates session identity and preserves only the workspace and session locators")
    func captureValidatesAndPreservesLocators() throws {
        let pane = try makePane(sessionID: "current-session")
        let mismatched = ConversationContextTransfer(
            sourcePaneID: pane.id,
            expectedSessionID: "dragged-session",
            title: "Example",
            agent: "Pi",
            path: "/synthetic"
        )
        #expect(throws: ConversationContextError.sessionChanged) {
            try ConversationContextReference.capture(
                transfer: mismatched,
                currentSourcePane: pane
            )
        }

        let unpinned = ConversationContextTransfer(
            sourcePaneID: pane.id,
            expectedSessionID: nil,
            title: "Example",
            agent: "Pi",
            path: "/synthetic"
        )
        #expect(throws: ConversationContextError.sessionIdentityUnavailable) {
            try ConversationContextReference.capture(
                transfer: unpinned,
                currentSourcePane: pane
            )
        }

        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let captured = try ConversationContextReference.capture(
            transfer: ConversationContextTransfer(pane: pane),
            currentSourcePane: pane,
            id: id
        )
        #expect(captured.id == id)
        #expect(captured.sourcePaneID == "machine-a|w1:p2")
        #expect(captured.sourceWorkspaceID == "w1")
        #expect(captured.sourceSessionID == "current-session")

        let storedFieldNames = Set(Mirror(reflecting: captured).children.compactMap(\.label))
        #expect(!storedFieldNames.contains("transcript"))
        #expect(!storedFieldNames.contains("turnCount"))
        #expect(!storedFieldNames.contains("isPartial"))
    }

    @Test("Prompt preserves locator order without embedding display metadata or transcript text")
    func promptContainsOnlyOrderedLocatorsBeforeRequest() {
        let first = makeReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workspace: "workspace-one",
            session: "session-one",
            title: "SECRET TITLE ONE"
        )
        let second = makeReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            workspace: "workspace-two",
            session: "session-two",
            title: "SECRET TITLE TWO"
        )
        let request = "Do this last."

        let prompt = ConversationContextReference.prompt(
            currentRequest: request,
            references: [first, second]
        )

        let firstLocator = "The user included Herdr workspace ID `workspace-one`, running Pi session ID `session-one`. Fetch that session's context from Herdr before handling the current request."
        let secondLocator = "The user included Herdr workspace ID `workspace-two`, running Pi session ID `session-two`. Fetch that session's context from Herdr before handling the current request."
        #expect(prompt == "\(firstLocator)\n\(secondLocator)\n\n\(ConversationContextReference.currentRequestBoundary)\n\(request)")
        #expect(prompt.range(of: firstLocator)!.lowerBound < prompt.range(of: secondLocator)!.lowerBound)
        #expect(!prompt.contains("SECRET TITLE"))
        #expect(!prompt.contains("/synthetic/project"))
        #expect(!prompt.contains("turn"))
        #expect(!prompt.contains("partial"))
        #expect(ConversationContextReference.prompt(currentRequest: request, references: []) == request)
    }

    @MainActor
    @Test("Per-destination state preserves order, deduplicates sessions, and removes only submitted IDs")
    func orderingDedupeAndExactRemoval() {
        let model = makeModel()
        let destination = "synthetic|w1:p9"
        let first = makeReference(id: UUID(), workspace: "w1", session: "same", title: "First")
        let duplicate = makeReference(id: UUID(), workspace: "w2", session: "same", title: "Updated")
        let second = makeReference(id: UUID(), workspace: "w2", session: "second", title: "Second")
        let addedDuringSend = makeReference(id: UUID(), workspace: "w3", session: "new", title: "New")

        #expect(model.stageCapturedConversationReference(first, for: destination))
        #expect(!model.stageCapturedConversationReference(duplicate, for: destination))
        #expect(model.stageCapturedConversationReference(second, for: destination))
        #expect(model.conversationReferences(for: destination) == [first, second])
        #expect(model.stageCapturedConversationReference(addedDuringSend, for: destination))
        model.removeConversationReferences(Set([first.id, second.id]), from: destination)

        #expect(model.conversationReferences(for: destination) == [addedDuringSend])
    }

    @MainActor
    @Test("Machine removal drops destination state while lightweight source references remain staged")
    func destinationPruning() throws {
        let model = makeModel()
        let destination = try #require(model.workspaces.first?.panes.first)
        let reference = makeReference(
            id: UUID(),
            sourcePaneID: "missing-machine|w9:p9",
            workspace: "w9",
            session: "gone-source",
            title: "Linked"
        )
        model.stageCapturedConversationReference(reference, for: destination.id)
        #expect(model.conversationReferences(for: destination.id) == [reference])

        model.removeMachine(id: destination.machineID)

        #expect(model.conversationReferences(for: destination.id).isEmpty)
    }

    @MainActor
    @Test("The conversation chip describes a linked Pi session and keeps its removal affordance")
    func chipRenderStructure() {
        let reference = makeReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            workspace: "w1",
            session: "session-a",
            title: "Design review"
        )
        #expect(reference.compactSummary == "Pi · project · linked Pi session")
        #expect(reference.accessibilityLabel == "Conversation context, Design review, Pi · project · linked Pi session")

        let host = NSHostingView(rootView: ConversationContextChip(reference: reference, remove: {}))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 80)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height >= 44)
    }

    private func makePane(sessionID: String, status: AgentStatus = .idle) throws -> HerdrPane {
        let object: [String: Any] = [
            "pane_id": "w1:p2",
            "terminal_id": "t1",
            "workspace_id": "w1",
            "tab_id": "tab1",
            "agent_status": status.rawValue,
            "cwd": "/synthetic/project",
            "label": "Example chat",
            "agent": "pi",
            "display_agent": "Pi",
            "pi_semantic": [
                "available": true,
                "connected": true,
                "protocol_version": 1,
                "session_id": sessionID,
                "capabilities": [:]
            ]
        ]
        return try JSONDecoder().decode(
            HerdrPane.self,
            from: JSONSerialization.data(withJSONObject: object)
        ).stamped(machineID: "machine-a")
    }

    private func makeReference(
        id: UUID,
        sourcePaneID: String = "machine-a|w1:p2",
        workspace: String,
        session: String,
        title: String
    ) -> ConversationContextReference {
        ConversationContextReference(
            id: id,
            sourcePaneID: sourcePaneID,
            sourceWorkspaceID: workspace,
            sourceSessionID: session,
            title: title,
            agent: "Pi",
            path: "/synthetic/project"
        )
    }

    @MainActor
    private func makeModel() -> HerdrAppModel {
        let suite = "ConversationContextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
    }
}
