import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Skim reply options")
@MainActor
struct SkimReplyTests {
    @Test("Old and malformed options keep the original summary usable")
    func optionalDecoding() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SkimReplyFixtures.skim)) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        document["actions"] = ["unexpected"]
        json["document"] = document
        let decoded = try JSONDecoder().decode(FirstMateSkim.self, from: JSONSerialization.data(withJSONObject: json))
        let reader = try #require(FirstMateSkimReader(skim: decoded, reply: SkimReplyFixtures.reply))
        #expect(reader.actions.isEmpty)
        #expect(!reader.sentence.isEmpty)
        document.removeValue(forKey: "actions")
        json["document"] = document
        let legacy = try JSONDecoder().decode(FirstMateSkim.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(FirstMateSkimReader(skim: legacy, reply: SkimReplyFixtures.reply)?.actions.isEmpty == true)
    }

    @Test("Options require a next step, bounded labels, and valid original references")
    func groundedOptions() throws {
        var skim = SkimReplyFixtures.skim
        var invalid = SkimReplyFixtures.actions[0]
        invalid.refs = ["s99"]
        var long = SkimReplyFixtures.actions[0]
        long.id = "too-long"
        long.label = "Please recover the saved checkpoint immediately"
        skim.document?.actions = [invalid, long] + SkimReplyFixtures.actions + SkimReplyFixtures.actions
        #expect(FirstMateSkimReader(skim: skim, reply: SkimReplyFixtures.reply)?.actions == SkimReplyFixtures.actions)
        skim.document?.blocks.removeLast()
        #expect(FirstMateSkimReader(skim: skim, reply: SkimReplyFixtures.reply)?.actions.isEmpty == true)
        #expect(FirstMateSkimReader(skim: skim, reply: "A different reply") == nil)
    }

    @Test("Selecting a reply sends only its exact label and prevents another send")
    func exactSend() async {
        let state = SkimDisplayState()
        let submission = SkimReplySubmission()
        var sent: [String] = []
        let context = SkimReplyContext(messageID: "latest") { sent.append($0); return true }
        await submission.send(SkimReplyFixtures.actions[0], context: context, state: state)
        await submission.send(SkimReplyFixtures.actions[1], context: context, state: state)
        #expect(sent == ["recover it"])
        #expect(state.sentReplyIDs == ["latest"])
    }

    @Test("A failed or stale send is retryable and disabled actions never send")
    func failedSend() async {
        let state = SkimDisplayState()
        let submission = SkimReplySubmission()
        var attempts = 0
        var context = SkimReplyContext(messageID: "latest", disabledReason: "Reconnect") { _ in attempts += 1; return attempts > 1 }
        await submission.send(SkimReplyFixtures.actions[0], context: context, state: state)
        #expect(attempts == 0)
        context.disabledReason = nil
        await submission.send(SkimReplyFixtures.actions[0], context: context, state: state)
        #expect(submission.failed && state.sentReplyIDs.isEmpty)
        await submission.send(SkimReplyFixtures.actions[0], context: context, state: state)
        #expect(!submission.failed && attempts == 2)
    }

    @Test("In-flight clicks are coalesced")
    func duplicateClick() async throws {
        let state = SkimDisplayState()
        let submission = SkimReplySubmission()
        var attempts = 0
        let context = SkimReplyContext(messageID: "latest") { _ in
            attempts += 1
            try? await Task.sleep(for: .milliseconds(20))
            return true
        }
        async let first: Void = submission.send(SkimReplyFixtures.actions[0], context: context, state: state)
        async let second: Void = submission.send(SkimReplyFixtures.actions[1], context: context, state: state)
        _ = await (first, second)
        #expect(attempts == 1)
    }

    @Test("A draft, active work, or lost connection disables quick replies")
    func protectsComposer() {
        #expect(SkimReplyAvailability.disabledReason(connected: true, busy: false, hasDraft: false) == nil)
        #expect(SkimReplyAvailability.disabledReason(connected: true, busy: false, hasDraft: true) != nil)
        #expect(SkimReplyAvailability.disabledReason(connected: true, busy: true, hasDraft: false) != nil)
        #expect(SkimReplyAvailability.disabledReason(connected: false, busy: false, hasDraft: false) != nil)
    }
}
