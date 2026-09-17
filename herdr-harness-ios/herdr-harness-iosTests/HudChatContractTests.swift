import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Saved HUD chat contract")
struct HudChatContractTests {
    @Test("Dedicated starts opt into durable action chats and omit home cwd")
    func startRequestWireShape() throws {
        let home = try object(
            HudChatStartRequest(
                prompt: "Plan the release",
                cwd: nil,
                model: "openai-codex/gpt-5.6-sol",
                thinkingLevel: "high",
                continueFromRunId: nil
            )
        )
        #expect(home["prompt"] as? String == "Plan the release")
        #expect(home["mode"] as? String == "act")
        #expect(home["profile"] as? String == "hud-chat-v1")
        #expect(home["cwd"] == nil)
        #expect(home["continueFromRunId"] == nil)

        let reply = try object(
            HudChatStartRequest(
                prompt: "Continue",
                cwd: nil,
                model: nil,
                thinkingLevel: "max",
                continueFromRunId: "agr_latest"
            )
        )
        #expect(reply["continueFromRunId"] as? String == "agr_latest")
        #expect(reply["cwd"] == nil)

        let custom = try object(
            HudChatStartRequest(
                prompt: "Inspect it",
                cwd: "/srv/synthetic-project",
                model: nil,
                thinkingLevel: nil,
                continueFromRunId: nil
            )
        )
        #expect(custom["cwd"] as? String == "/srv/synthetic-project")
    }

    @Test("Run, catalog, history, and capabilities decode additive fields")
    func additiveDecode() throws {
        let run = try JSONDecoder().decode(HeadlessAgentRun.self, from: Data(#"""
        {"id":"agr_one","status":"completed","mode":"act","profile":"hud-chat-v1","prompt":"Hello","cwd":"/srv/example","response":"Hi","error":null,"createdAt":"2026-09-17T00:00:00Z","threadRootRunId":"agr_one"}
        """#.utf8))
        #expect(run.profile == "hud-chat-v1")
        #expect(run.cwd == "/srv/example")

        let catalog = try JSONDecoder().decode(HudChatCatalog.self, from: Data(#"""
        {"chats":[{"id":"agr_one","title":"Hello","updatedAt":"2026-09-17T00:00:00Z","latestRunId":"agr_two","turnCount":2,"status":"completed","sessionId":"session","promotedPaneId":null,"cwd":"/srv/example"}],"nextOffset":50}
        """#.utf8))
        #expect(catalog.chats.first?.cwd == "/srv/example")
        #expect(catalog.nextOffset == 50)

        let history = try JSONDecoder().decode(HudChatHistory.self, from: Data(#"""
        {"turns":[],"rootRunId":"agr_one","latestRunId":"agr_two","promotedPaneId":"w1:p2","nextOffset":null}
        """#.utf8))
        #expect(history.rootRunId == "agr_one")
        #expect(history.latestRunId == "agr_two")
        #expect(history.promotedPaneId == "w1:p2")

        let modern = try JSONDecoder().decode(HudChatCapabilities.self, from: Data(#"""
        {"profiles":["contextual-question-v1","hud-chat-v1"],"hudChatWorkingDirectory":true}
        """#.utf8))
        #expect(modern.supportsHudChats)
        #expect(modern.hudChatWorkingDirectory)

        let legacy = try JSONDecoder().decode(HudChatCapabilities.self, from: Data(#"{"profiles":["hud-chat-v1"]}"#.utf8))
        #expect(legacy.supportsHudChats)
        #expect(!legacy.hudChatWorkingDirectory)
    }

    @Test("Legacy runs still decode without cwd")
    func legacyRunDecode() throws {
        let run = try JSONDecoder().decode(HeadlessAgentRun.self, from: Data(#"""
        {"id":"agr_old","status":"completed","prompt":"Hello","response":"Hi","error":null,"createdAt":"2026-09-17T00:00:00Z"}
        """#.utf8))
        #expect(run.cwd == nil)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
