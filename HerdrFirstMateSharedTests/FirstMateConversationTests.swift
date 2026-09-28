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

    @Test("A checkpoint owns one turn while its closing reply keeps its original feedback identity")
    func checkpointGroupsOnlyItsClosingReply() throws {
        let messages = try decodeMessages([
            #"{"id":"human","role":"user","text":"Proceed"}"#,
            #"{"id":"checkpoint","role":"assistant","text":"Review this result","metadata":{"checkpoint":true,"turn_id":"human","visit_id":"visit"}}"#,
            #"{"id":"closing","role":"assistant","text":"Would you like to review?","metadata":{"in_reply_to":"human"}}"#,
            #"{"id":"next-reply","role":"assistant","text":"Would you like to review?","metadata":{"in_reply_to":"next-human"}}"#,
        ])
        let entries = FirstMateConversationEntry.make(messages: messages)
        #expect(entries.map(\.id) == ["human", "checkpoint", "next-reply"])
        #expect(entries[1].additionalReplies == [messages[2]])
        #expect(entries[1].message == messages[1])
        #expect(FirstMateFeedbackEligibility.isEligible(entries[1].additionalReplies[0]))
        #expect(messages.map(\.id) == ["human", "checkpoint", "closing", "next-reply"])
    }

    @Test("Missing, malformed, background and foreign provenance cannot hide replies")
    func unknownProvenanceIsNotCollapsed() throws {
        let messages = try decodeMessages([
            #"{"id":"old-checkpoint","role":"assistant","text":"Choose a next step","metadata":{"checkpoint":true}}"#,
            #"{"id":"old-reply","role":"assistant","text":"Choose a next step"}"#,
            #"{"id":"broken","role":"assistant","text":"Choose a next step","metadata":{"turn_id":12}}"#,
            #"{"id":"background","role":"assistant","text":"Done","visibility":"background","metadata":{"checkpoint":true,"turn_id":"turn"}}"#,
            #"{"id":"reply","role":"assistant","text":"Choose a next step","metadata":{"in_reply_to":"turn"}}"#,
            #"{"id":"foreign","feature_id":"other-feature","role":"assistant","text":"Done","metadata":{"checkpoint":true,"turn_id":"turn"}}"#,
        ])
        let entries = FirstMateConversationEntry.make(messages: messages)
        #expect(entries.map(\.id) == ["old-checkpoint", "old-reply", "broken", "reply", "foreign"])
        #expect(entries.allSatisfy { $0.additionalReplies.isEmpty })
        #expect(messages[2].metadata == nil)
        let roundTrip = try JSONDecoder().decode([FirstMateMessage].self, from: JSONEncoder().encode(messages))
        #expect(roundTrip == messages)
    }

    @Test("Only the current visit's latest checkpoint is marked as the pending decision")
    func pendingDecisionFollowsWorkflowState() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.id = "f"
        snapshot.feature.currentVisitID = "current"
        snapshot.feature.status = "awaiting_direction"
        snapshot.messages = try decodeMessages([
            #"{"id":"old","role":"assistant","text":"Old question","metadata":{"checkpoint":true,"turn_id":"old-turn","visit_id":"old"}}"#,
            #"{"id":"current","role":"assistant","text":"Current question","metadata":{"checkpoint":true,"turn_id":"current-turn","visit_id":"current"}}"#,
            #"{"id":"closing","role":"assistant","text":"Closing question","metadata":{"in_reply_to":"current-turn"}}"#,
        ])
        #expect(snapshot.pendingDecisionMessageID == "current")
        #expect(snapshot.conversationEntries.map(\.id) == ["old", "current"])
        for status in ["running", "recovering", "completed", "paused", "blocked"] {
            snapshot.feature.status = status
            #expect(snapshot.pendingDecisionMessageID == nil)
        }
        snapshot.feature.status = "awaiting_direction"
        snapshot.feature.currentVisitID = "next"
        #expect(snapshot.pendingDecisionMessageID == nil)
    }

    private func decodeMessages(_ rows: [String]) throws -> [FirstMateMessage] {
        try rows.map { row in
            var value = try #require(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            if value["feature_id"] == nil { value["feature_id"] = "f" }
            value["status"] = "done"
            value["created_at"] = "2026-01-01T00:00:00Z"
            return try JSONDecoder().decode(FirstMateMessage.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }
}
