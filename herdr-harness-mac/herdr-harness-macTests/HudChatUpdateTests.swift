import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD history and sidebar reminders")
@MainActor
struct HudChatUpdateTests {
    @Test("Manual unread persists locally without adding an alert or changing the live status")
    func sidebarReminder() throws {
        let suite = "hud-reminder-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        let pane = try #require(model.workspaces.first?.panes.first)
        let alerts = model.alerts
        let originalStatus = pane.agentStatus
        model.markPaneUnread(pane)
        #expect(model.manuallyUnreadPaneIDs.contains(pane.id))
        #expect(model.unreadPaneIDs.contains(pane.id))
        #expect(model.alerts == alerts)
        #expect(model.pane(id: pane.id)?.agentStatus == originalStatus)
        let restored = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        #expect(restored.manuallyUnreadPaneIDs.contains(pane.id))
        model.openPane(id: pane.id)
        #expect(!model.manuallyUnreadPaneIDs.contains(pane.id))
        #expect(defaults.stringArray(forKey: "herdr.sidebar.manuallyUnread")?.isEmpty == true)
    }

    @Test("Only HUD requests opt into the durable full-access profile")
    func profileWireContract() throws {
        let hud = HeadlessAgentStartRequest(prompt: "Plan a garden", mode: .act, profile: "hud-chat-v1")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hud)) as? [String: Any]
        #expect(encoded?["profile"] as? String == "hud-chat-v1")
        #expect(encoded?["mode"] as? String == "act")
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HeadlessAgentStartRequest(prompt: "Question"))) as? [String: Any]
        #expect(legacy?["profile"] == nil)
    }

    @Test("HUD history decodes pagination and the terminal destination")
    func historyContract() throws {
        let data = Data(#"{"chats":[{"id":"agr_0123456789ab","title":"Garden ideas","updatedAt":"2026-09-09T12:00:00Z","latestRunId":"agr_0123456789ab","turnCount":4,"status":"promoted","sessionId":"example-session","promotedPaneId":"example-pane"}],"nextOffset":50}"#.utf8)
        let catalog = try JSONDecoder().decode(HudChatCatalog.self, from: data)
        #expect(catalog.nextOffset == 50)
        #expect(catalog.chats.first?.promotedPaneId == "example-pane")
        #expect(catalog.chats.first?.turnCount == 4)
    }
}
