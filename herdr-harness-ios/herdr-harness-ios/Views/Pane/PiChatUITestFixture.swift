import Foundation

#if DEBUG
/// An entirely synthetic transcript in the real Agents workspace. Available
/// only with an explicit UI-test argument, and only installed for demo panes.
enum PiChatUITestFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-HerdrAgentChatFixture") }
    static let capability = try! JSONDecoder().decode(PiSemanticCapability.self, from: Data(
        #"{"available":true,"connected":true,"protocolVersion":1,"sessionId":"sample-reading-chat","capabilities":{"prompt":true}}"#.utf8
    ))

    @MainActor static func install(on store: PiConversationStore) {
        store.snapshotProvider = { pane in
            let entries: [[String: Any]] = [
                ["type": "message", "id": "sample-request", "message": [
                    "role": "user", "content": "Prepare a reading list with three fictional books and explain the export format."
                ]],
                ["type": "message", "id": "sample-reply", "message": [
                    "role": "assistant", "content": [["type": "text", "text": """
                    ## Your reading list is ready

                    The sample catalog includes **The Glass Orchard**, **A Map of Quiet Rivers**, and **The Lantern Keeper**.

                    Each entry contains a title, a short description, and a reading status. The export keeps those fields in a consistent order so they are easy to scan on any screen.

                    ### What changed

                    - Added all three fictional titles to the catalog.
                    - Kept the descriptions readable without truncating the text.
                    - Checked the exported file against the original list.

                    You can review the entries here, then send any adjustments from the composer below.
                    """]]
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: [
                "pane_id": pane.paneID, "available": true, "connected": true,
                "session": ["id": "sample-reading-chat"],
                "state": ["model": ["provider": "sample", "id": "sample-pro", "name": "Sample Pro"],
                          "thinkingLevel": "high", "context": ["tokens": 8_400, "contextWindow": 128_000]],
                "entries": entries, "pending_interactions": [], "cursor": "1", "oldest_cursor": "1", "truncated": false,
            ])
            return try JSONDecoder().decode(PiConversationSnapshot.self, from: data)
        }
        store.eventsProvider = { _, _ in AsyncThrowingStream { _ in } }
    }
}
#endif
