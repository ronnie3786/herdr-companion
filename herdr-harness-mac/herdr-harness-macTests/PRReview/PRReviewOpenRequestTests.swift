import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review open requests")
struct PRReviewOpenRequestTests {
    @Test("A valid request parses")
    func validRequestParses() throws {
        let request = try #require(
            PRReviewOpenRequest(
                url: URL(
                    string: "herdr://pr-review?review_id=prr_0123456789ab&server_url=https%3A%2F%2Fdev.example.test&file=Sources%2FGarden.swift&line=12&side=before&tab=agents"
                )!
            )
        )

        #expect(request.reviewID == "prr_0123456789ab")
        #expect(request.serverURL == "https://dev.example.test")
        #expect(request.line == 12)
        #expect(request.side == .before)
        #expect(request.tab == .agents)
    }

    @Test("An HTTP remote URL is rejected")
    func httpRemoteIsRejected() {
        #expect(
            PRReviewOpenRequest(
                url: URL(
                    string: "herdr://pr-review?review_id=prr_0123456789ab&server_url=http%3A%2F%2Fdev.example.test"
                )!
            ) == nil
        )
    }

    @Test("Duplicate query keys are rejected")
    func duplicateKeysAreRejected() {
        #expect(
            PRReviewOpenRequest(
                url: URL(
                    string: "herdr://pr-review?review_id=prr_0123456789ab&review_id=prr_other&server_url=https%3A%2F%2Fdev.example.test"
                )!
            ) == nil
        )
    }

    @Test("Invalid tab and line values are rejected")
    func badTabAndLineAreRejected() {
        #expect(
            PRReviewOpenRequest(
                url: URL(
                    string: "herdr://pr-review?review_id=prr_0123456789ab&server_url=https%3A%2F%2Fdev.example.test&tab=unknown"
                )!
            ) == nil
        )
        #expect(
            PRReviewOpenRequest(
                url: URL(
                    string: "herdr://pr-review?review_id=prr_0123456789ab&server_url=https%3A%2F%2Fdev.example.test&line=zero"
                )!
            ) == nil
        )
    }
}
