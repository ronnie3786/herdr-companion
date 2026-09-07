import Foundation

/// Sample-only content for Herdr's existing demo mode and UI checks.
enum RemoteNotesFixtures {
    static func response(machineID: String) throws -> RemoteNotesResponse {
        let primary = machineID == "demo1"
        let payload: [String: Any] = [
            "ok": true,
            "revision": 1,
            "deletedIDs": [],
            "notes": [[
                "id": primary ? "11111111-1111-1111-1111-111111111111" : "22222222-2222-2222-2222-222222222222",
                "title": primary ? "Sample release checklist" : "Sample weekend ideas",
                "body": primary
                    ? "Review the new HUD bubbles.\nCheck that attachments stay with their response.\nTry the Notes tab on your iPhone.\n\nThis is sample content for demo mode."
                    : "Walk by the lake.\nRead a new book.\n\nThis is sample content for demo mode.",
                "color": primary ? "yellow" : "blue",
                "createdAt": 810_000_000,
                "updatedAt": 810_000_060,
                "revision": 1,
                "actions": [],
                "links": [],
            ]],
        ]
        return try JSONDecoder().decode(RemoteNotesResponse.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
