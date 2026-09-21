import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief identity")
struct ResponseBriefIdentityTests {
    private let chat = ResponseBriefChatIdentity(
        machineID: "synthetic-machine",
        paneID: "w1:p1",
        sessionID: "01a00000-0000-7000-8000-000000000001"
    )
    private let responseTimestamp = Date(timeIntervalSince1970: 1_800_000_100)
    private let userTimestamp = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Evidence hashes exact content and copies only supplied timestamps")
    func evidenceCopiesObservedData() {
        let evidence = ResponseBriefIdentityEvidence(
            responseText: "a",
            responseTimestamp: nil,
            userText: "Question",
            userTimestamp: nil
        )

        #expect(evidence.responseTextHash == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        #expect(evidence.responseTimestamp == nil)
        #expect(evidence.userTextHash == ResponseBriefIdentityEvidence.hash("Question"))
        #expect(evidence.userTimestamp == nil)
    }

    @Test("A live identifier and its persisted entry verify as one continuation")
    func liveAndPersistedContinuation() {
        let live = makeSource(
            responseID: "live:synthetic:1800000100",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let persisted = makeSource(
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )

        #expect(ResponseBriefIdentity.match(live, persisted) == .verifiedContinuation)
        #expect(ResponseBriefIdentity.match(persisted, live) == .verifiedContinuation)
    }

    @Test("Exact identifiers match without needing evidence")
    func exactIdentifierMatch() {
        let lhs = plainSource(responseID: "entry-a1")
        let rhs = plainSource(responseID: "entry-a1")

        #expect(lhs.identity == nil)
        #expect(ResponseBriefIdentity.match(lhs, rhs) == .exactIdentifier)
    }

    @Test("Different chats never match even with identical text")
    func differentChatsNeverMatch() {
        let lhs = makeSource(
            chat: chat,
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let rhs = makeSource(
            chat: .init(
                machineID: "synthetic-machine",
                paneID: "w1:p1",
                sessionID: "01a00000-0000-7000-8000-000000000002"
            ),
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )

        #expect(ResponseBriefIdentity.match(lhs, rhs) == nil)
    }

    @Test("Content-only and incomplete evidence never matches")
    func contentOnlyEvidenceNeverMatches() {
        let withTimestamp = makeSource(
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let withoutTimestamp = makeSource(
            responseID: "live:synthetic:1",
            responseTimestamp: nil,
            userText: "Question",
            userTimestamp: nil
        )
        let missingEvidence = plainSource(responseID: "live:synthetic:2")

        #expect(missingEvidence.identity == nil)
        #expect(ResponseBriefIdentity.match(withTimestamp, withoutTimestamp) == nil)
        #expect(ResponseBriefIdentity.match(withoutTimestamp, withTimestamp) == nil)
        #expect(ResponseBriefIdentity.match(withTimestamp, missingEvidence) == nil)
        #expect(ResponseBriefIdentity.match(withoutTimestamp, missingEvidence) == nil)
    }

    @Test("Conflicting timestamps or user content never matches")
    func conflictingEvidenceNeverMatches() {
        let reference = makeSource(
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let differentResponseTimestamp = makeSource(
            responseID: "live:synthetic:1",
            responseTimestamp: responseTimestamp.addingTimeInterval(1),
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let differentUserTimestamp = makeSource(
            responseID: "live:synthetic:2",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp.addingTimeInterval(1)
        )
        let differentUserText = makeSource(
            responseID: "live:synthetic:3",
            responseTimestamp: responseTimestamp,
            userText: "A different question",
            userTimestamp: userTimestamp
        )
        let differentResponseText = makeSource(
            responseID: "live:synthetic:4",
            text: "A different answer",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )

        #expect(ResponseBriefIdentity.match(reference, differentResponseTimestamp) == nil)
        #expect(ResponseBriefIdentity.match(reference, differentUserTimestamp) == nil)
        #expect(ResponseBriefIdentity.match(reference, differentUserText) == nil)
        #expect(ResponseBriefIdentity.match(reference, differentResponseText) == nil)
    }

    @Test("User text corroborates continuity when one projection lacks a user timestamp")
    func userTextCorroboration() throws {
        let anchored = makeSource(
            responseID: "entry-a1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: nil
        )
        let later = makeSource(
            responseID: "live:synthetic:1",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )

        let anchoredEvidence = try #require(anchored.identity)
        let laterEvidence = try #require(later.identity)
        #expect(ResponseBriefIdentity.verifiesContinuity(anchoredEvidence, laterEvidence))
        #expect(ResponseBriefIdentity.match(anchored, later) == .verifiedContinuation)
    }

    @Test("Unique candidate resolution refuses zero, several, and content-only matches")
    func uniqueCandidateResolution() {
        let anchor = ResponseBriefIdentityEvidence(
            responseText: "Shared answer",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let exact = makeSource(responseID: "entry-a1")
        let single = makeSource(
            responseID: "live:synthetic:1",
            text: "Shared answer",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let duplicate = makeSource(
            responseID: "live:synthetic:2",
            text: "Shared answer",
            responseTimestamp: responseTimestamp,
            userText: "Question",
            userTimestamp: userTimestamp
        )
        let unrelated = makeSource(
            responseID: "live:synthetic:3",
            text: "Something else",
            responseTimestamp: responseTimestamp.addingTimeInterval(5),
            userText: "Question",
            userTimestamp: userTimestamp
        )

        #expect(ResponseBriefIdentity.uniqueVerifiedCandidate(
            responseID: "entry-a1",
            identity: anchor,
            among: [unrelated, exact]
        )?.responseID == "entry-a1")
        #expect(ResponseBriefIdentity.uniqueVerifiedCandidate(
            responseID: "missing-id",
            identity: anchor,
            among: [unrelated, single]
        )?.responseID == "live:synthetic:1")
        #expect(ResponseBriefIdentity.uniqueVerifiedCandidate(
            responseID: "missing-id",
            identity: anchor,
            among: [single, duplicate]
        ) == nil)
        #expect(ResponseBriefIdentity.uniqueVerifiedCandidate(
            responseID: "missing-id",
            identity: anchor,
            among: [unrelated]
        ) == nil)
    }

    @Test("Ambiguity is rejected when identical text has no observed timestamps")
    func ambiguousContentOnlyCandidates() {
        let anchor = ResponseBriefIdentityEvidence(
            responseText: "Shared answer",
            responseTimestamp: nil,
            userText: "Question",
            userTimestamp: nil
        )
        let first = makeSource(responseID: "live:synthetic:1", text: "Shared answer")
        let second = makeSource(responseID: "live:synthetic:2", text: "Shared answer")

        #expect(ResponseBriefIdentity.uniqueVerifiedCandidate(
            responseID: "missing-id",
            identity: anchor,
            among: [first, second]
        ) == nil)
    }

    private func plainSource(responseID: String) -> ResponseBriefSource {
        ResponseBriefSource(
            chat: chat,
            responseID: responseID,
            text: "Shared answer",
            currentUserText: nil,
            previousUserText: nil,
            previousAssistantText: nil
        )
    }

    private func makeSource(
        chat: ResponseBriefChatIdentity? = nil,
        responseID: String,
        text: String = "Shared answer",
        responseTimestamp: Date? = nil,
        userText: String? = nil,
        userTimestamp: Date? = nil
    ) -> ResponseBriefSource {
        ResponseBriefSource(
            chat: chat ?? self.chat,
            responseID: responseID,
            text: text,
            currentUserText: userText,
            previousUserText: nil,
            previousAssistantText: nil,
            identity: ResponseBriefIdentityEvidence(
                responseText: text,
                responseTimestamp: responseTimestamp,
                userText: userText,
                userTimestamp: userTimestamp
            )
        )
    }
}
