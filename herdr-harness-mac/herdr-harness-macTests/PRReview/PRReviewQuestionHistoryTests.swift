import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review saved questions")
struct PRReviewQuestionHistoryTests {
    @Test("Questions survive relaunch and keep host, file, and revision anchors")
    func persistsAndScopesQuestions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("questions.json")
        let history = PRReviewQuestionHistory(url: url)
        var question = fixture()
        try history.append(question)
        question.id = "second-question"
        question.machineID = "other-host"
        try history.append(question)
        let reopened = PRReviewQuestionHistory(url: url)
        let matches = reopened.questions(machineID: "synthetic-host", reviewID: "review", path: "Sources/Garden.swift")
        #expect(matches.count == 1)
        #expect(matches.first?.headSHA == "original-head")
        #expect(matches.first?.context == fixture().context)
        #expect(reopened.questions(machineID: "synthetic-host", reviewID: "other-review", path: "Sources/Garden.swift").isEmpty)
        #expect(reopened.questions(machineID: "synthetic-host", reviewID: "review", path: "Sources/Other.swift").isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Corrupt history is preserved rather than overwritten")
    func preservesUnreadableHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not valid JSON".utf8)
        try original.write(to: url)
        let history = PRReviewQuestionHistory(url: url)
        #expect(history.loadError != nil)
        #expect(throws: (any Error).self) { try history.append(fixture()) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Impact reasons are visible guidance, never invented reassurance")
    func impactReasons() {
        var file = PRReviewDemo.snapshot().files[0]
        file.impact = .low
        file.impactReason = "Only changes a comment; runtime behavior is unchanged."
        #expect(file.impactExplanation == "Why low: Only changes a comment; runtime behavior is unchanged.")
        file.impactReason = " "
        #expect(file.impactExplanation.contains("No explanation was saved"))
        file.impact = nil
        #expect(file.impactExplanation.contains("Not ranked yet"))
    }

    @Test("Failed or preparing refresh keeps a populated review navigable")
    func refreshKeepsFilesVisible() {
        for status in [PRReviewStatus.failed, .preparing] {
            #expect(PRReviewFilesPresentation.resolve(status: status, reviewError: "Refresh failed", hasSnapshot: true,
                                                     fileCount: 2, visibleFileCount: 1) == .content)
            #expect(PRReviewFilesPresentation.resolve(status: status, reviewError: "Refresh failed", hasSnapshot: true,
                                                     fileCount: 2, visibleFileCount: 0) == .noFilterMatches)
        }
    }

    private func fixture() -> PRReviewQuestionHistory.Question {
        .init(id: "question", machineID: "synthetic-host", reviewID: "review", path: "Sources/Garden.swift",
              baseSHA: "original-base", headSHA: "original-head", prompt: "Why did this change?",
              title: "PR #42", checkoutPath: "/synthetic/checkout",
              context: .init(snapshotId: "snapshot", capturedAt: "2026-01-01T00:00:00Z",
                             source: .init(feature: "pr-review.diff", instanceId: "review"),
                             items: [.init(id: "selection", kind: "text-selection.v1", label: "after lines 2–3", text: "let seed = 1")]),
              createdAt: Date(timeIntervalSince1970: 0))
    }
}
