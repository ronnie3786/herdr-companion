import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("HUD chat skim decoding")
struct HudChatSkimDecodingTests {
    @Test("Runs from older companions have no skim and still show the full response")
    func runWithoutSkim() throws {
        let run = try SkimFixture.uploadRun(skimJSON: nil)

        #expect(run.skim == nil)
        #expect(run.response == SkimFixture.uploadReply)
        #expect(FirstMateSkimReader(skim: run.skim, reply: run.response ?? "") == nil)

        let explicitNull = try SkimFixture.uploadRun(skimJSON: NSNull())
        #expect(explicitNull.skim == nil)
    }

    @Test("Pending and failed skims decode their status but never produce a reader")
    func pendingAndFailed() throws {
        for (raw, status) in [("pending", FirstMateSkim.Status.pending), ("failed", .failed), ("rejected", .rejected)] {
            let run = try SkimFixture.uploadRun(skimJSON: [
                "status": raw, "format": "breath_tight", "prompt_version": "skim-v2",
                "segmenter_version": 1, "skim_version": 1,
            ] as [String: Any])
            #expect(run.skim?.status == status)
            #expect(run.skim?.document == nil)
            #expect(FirstMateSkimReader(skim: run.skim, reply: SkimFixture.uploadReply) == nil)
        }
    }

    @Test("A ready skim decodes exactly and reads against the turn's response")
    func readySkim() throws {
        let skim = SkimFixture.uploadSkim()
        let run = try SkimFixture.uploadRun(skimJSON: SkimFixture.json(skim))

        #expect(run.skim == skim)
        #expect(run.skim?.replySHA256 == SkimFixture.sha256(SkimFixture.uploadReply))
        let reader = try #require(FirstMateSkimReader(skim: run.skim, reply: run.response ?? ""))
        #expect(reader.sentence.map(\.plainText).joined().hasPrefix("The upload test is flaky"))
        #expect(reader.nextSteps.count == 1)
        #expect(reader.restCount == 0)
    }

    @Test("A skim for different text is ignored")
    func skimForAnotherReply() throws {
        let run = try SkimFixture.uploadRun(skimJSON: SkimFixture.json(SkimFixture.checkoutSkim()))
        #expect(run.skim?.status == .ready)
        #expect(FirstMateSkimReader(skim: run.skim, reply: run.response ?? "") == nil)
    }

    @Test("A malformed skim never fails the run", arguments: [
        "\"garbage\"",
        "42",
        "[1, 2, 3]",
        #"{"status": 7}"#,
        #"{"status": "exploded"}"#,
        #"{"status": "ready", "document": {"version": "one"}, "segments": "nope", "reply_sha256": 5}"#,
        #"{"status": "ready", "document": {"version": 1, "format": "breath_tight", "status": "answer", "statusLabel": "Answer", "blocks": [{"kind": "say", "tokens": [{"t": "sparkle"}]}], "anchors": []}, "segments": [{"id": "s1"}]}"#,
    ])
    func malformedSkim(skimJSON: String) throws {
        let skim = try JSONSerialization.jsonObject(with: Data(skimJSON.utf8), options: .fragmentsAllowed)
        let run = try SkimFixture.uploadRun(skimJSON: skim)

        #expect(run.id == "agr_synthetic_upload")
        #expect(run.status == .completed)
        #expect(run.response == SkimFixture.uploadReply)
        #expect(run.threadRootRunId == "agr_synthetic_upload")
        #expect(FirstMateSkimReader(skim: run.skim, reply: run.response ?? "") == nil)
        if let skim = run.skim {
            #expect(skim.document == nil || skim.segments == nil || skim.status != .ready)
        }
    }

    @Test("Unknown statuses decode as unknown")
    func unknownStatus() throws {
        let run = try SkimFixture.uploadRun(skimJSON: ["status": "exploded"])
        #expect(run.skim?.status == .unknown)
    }

    @Test("A history page with one malformed skim still decodes every turn")
    func historyPageWithMalformedSkim() throws {
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SkimFixture.uploadSkim()))
        let page: [String: Any] = [
            "turns": [
                turnJSON(id: "agr_one", skim: "not a skim"),
                turnJSON(id: "agr_two", skim: good),
            ],
            "rootRunId": "agr_one",
            "latestRunId": "agr_two",
            "promotedPaneId": NSNull(),
            "nextOffset": NSNull(),
        ]
        let history = try JSONDecoder().decode(HudChatHistory.self, from: JSONSerialization.data(withJSONObject: page))

        #expect(history.turns.map(\.id) == ["agr_one", "agr_two"])
        #expect(history.turns[0].skim == nil)
        #expect(history.turns[1].skim?.status == .ready)
    }

    @Test("The other run fields keep the synthesized decoder's rules")
    func requiredFieldsStillRequired() throws {
        let missingPrompt: [String: Any] = ["id": "agr_bad", "status": "completed", "createdAt": "2026-09-26T12:00:00Z"]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HeadlessAgentRun.self, from: JSONSerialization.data(withJSONObject: missingPrompt))
        }
    }

    private func turnJSON(id: String, skim: Any) -> [String: Any] {
        [
            "id": id, "status": "completed", "mode": "act", "prompt": "Synthetic question",
            "response": SkimFixture.uploadReply, "error": NSNull(), "createdAt": "2026-09-26T12:00:00Z",
            "threadRootRunId": "agr_one", "skim": skim,
        ]
    }
}
