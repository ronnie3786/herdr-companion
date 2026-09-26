import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate conversation and journal")
struct FirstMateConversationTests {
    @Test("Only conversation rows reach the chat; older companions omit visibility")
    func conversationVisibility() throws {
        let json = """
        [{"id":"m1","feature_id":"f","role":"user","text":"Build it","status":"done","created_at":"2026-01-01T00:00:00Z","visibility":"conversation"},
         {"id":"m2","feature_id":"f","role":"system","text":"Lane 1 reported success","status":"done","created_at":"2026-01-01T00:00:01Z","visibility":"background"},
         {"id":"m3","feature_id":"f","role":"assistant","text":"Lane 1 closed out clean.","status":"done","created_at":"2026-01-01T00:00:02Z","visibility":"background"},
         {"id":"m4","feature_id":"f","role":"assistant","text":"Stage done.","status":"done","created_at":"2026-01-01T00:00:03Z","visibility":"conversation"},
         {"id":"m5","feature_id":"f","role":"assistant","text":"Older companion reply.","status":"done","created_at":"2026-01-01T00:00:04Z"}]
        """
        let messages = try JSONDecoder().decode([FirstMateMessage].self, from: Data(json.utf8))
        #expect(messages.filter(\.isConversation).map(\.id) == ["m1", "m4", "m5"])
        #expect(messages[4].visibility == nil)
        let encoded = try #require(String(data: JSONEncoder().encode(messages[4]), encoding: .utf8))
        #expect(!encoded.contains("visibility"))
    }

    @Test("Journal milestones include First Mate's notes and exclude bookkeeping")
    func journalMilestones() {
        #expect(FirstMateEvent.isMilestone("coordinator.note"))
        #expect(FirstMateEvent.isMilestone("visit.awaiting_direction"))
        #expect(FirstMateEvent.isMilestone("assignment.outcome"))
        #expect(FirstMateEvent.isMilestone("demo.visit_updated"))
        for bookkeeping in ["message.claimed", "message.processed", "execution.stopped", "session.bound", "pi.message_end"] {
            #expect(!FirstMateEvent.isMilestone(bookkeeping))
        }
    }
}
