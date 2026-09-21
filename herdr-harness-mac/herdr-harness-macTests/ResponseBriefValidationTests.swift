import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief validation")
struct ResponseBriefValidationTests {
    private let source = "first\r\n\n```swift\nlet value = 1\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |\n" + String(repeating: "x", count: 500)

    @Test("Valid ranges extract exact LF slices while preserving CR")
    func exactExtraction() throws {
        let brief = try decode("""
        {"version":1,"title":"Result","summary":"The implementation is ready with one caveat.","points":[{"text":"Keep the CR byte.","startLine":1,"endLine":2}],"details":[{"label":"See implementation code","kind":"code","startLine":3,"endLine":5},{"label":"View comparison table","kind":"table","startLine":7,"endLine":9}]}
        """)
        #expect(brief.sourceSlice(startLine: 1, endLine: 2, source: source) == "first\r\n")
        #expect(brief.sourceSlice(startLine: 3, endLine: 5, source: source) == "```swift\nlet value = 1\n```")
        #expect(brief.sourceSlice(startLine: 7, endLine: 9, source: source) == "| A | B |\n| - | - |\n| 1 | 2 |")
    }

    @Test("LF splitting preserves CRLF, trailing empties, bare CR, emoji, and combining scalars")
    func scalarSafeLineSplitting() throws {
        let exact = "first\r\n\nbare\rvalue\n🪻 cafe\u{301}\n"
        let brief = try ResponseBrief.decodeValidated(
            Data(#"{"version":1,"title":"Exact","summary":"Every source byte remains available.","points":[],"details":[]}"#.utf8),
            source: exact + String(repeating: "z", count: 240)
        )

        #expect(ResponseBriefSourceLines.split(exact) == ["first\r", "", "bare\rvalue", "🪻 cafe\u{301}", ""])
        #expect(brief.sourceSlice(startLine: 1, endLine: 2, source: exact) == "first\r\n")
        #expect(brief.sourceSlice(startLine: 3, endLine: 4, source: exact) == "bare\rvalue\n🪻 cafe\u{301}")
        #expect(brief.sourceSlice(startLine: 5, endLine: 5, source: exact) == "")
        #expect(ResponseBriefSourceLines.split(exact).joined(separator: "\n") == exact)
    }

    @Test("Unknown keys and unsupported detail kinds are rejected", arguments: [
        #"{"version":1,"title":"T","summary":"S","points":[],"details":[],"html":"<script>"}"#,
        #"{"version":1,"title":"T","summary":"S","points":[],"details":[{"label":"Open URL","kind":"link","startLine":1,"endLine":1}]}"#,
        #"{"version":1,"title":"T","summary":"S","points":[{"text":"P","startLine":true,"endLine":1}],"details":[]}"#,
    ])
    func rejectsInvalidSchema(json: String) {
        #expect(throws: ResponseBriefValidationError.self) {
            try decode(json)
        }
    }

    @Test("Out-of-range and reversed references are rejected", arguments: [
        #"{"version":1,"title":"T","summary":"S","points":[{"text":"P","startLine":0,"endLine":1}],"details":[]}"#,
        #"{"version":1,"title":"T","summary":"S","points":[],"details":[{"label":"Read caveat","kind":"detail","startLine":4,"endLine":3}]}"#,
        #"{"version":1,"title":"T","summary":"S","points":[],"details":[{"label":"Read caveat","kind":"detail","startLine":1,"endLine":99}]}"#,
    ])
    func rejectsRanges(json: String) {
        #expect(throws: ResponseBriefValidationError.invalidLineRange) {
            try decode(json)
        }
    }

    @Test("A short single-line source accepts a line-1 reference and rejects a second line")
    func shortSourceLineBoundary() throws {
        let accepted = #"{"version":1,"title":"T","summary":"Done.","points":[{"text":"Read it.","startLine":1,"endLine":1}],"details":[]}"#
        let rejected = #"{"version":1,"title":"T","summary":"Done.","points":[{"text":"Read it.","startLine":1,"endLine":2}],"details":[]}"#

        let brief = try ResponseBrief.decodeValidated(Data(accepted.utf8), source: "Already concise.", length: .minimal)
        #expect(brief.points.first?.endLine == 1)
        #expect(throws: ResponseBriefValidationError.invalidLineRange) {
            try ResponseBrief.decodeValidated(Data(rejected.utf8), source: "Already concise.", length: .minimal)
        }
    }

    @Test("Visible point and detail grammar is tightly bounded", arguments: [
        #"{"version":1,"title":"T","summary":"Direct result.","points":[{"text":"First caveat.","startLine":1,"endLine":1},{"text":"Second caveat.","startLine":1,"endLine":1}],"details":[]}"#,
        #"{"version":1,"title":"T","summary":"Direct result.","points":[],"details":[{"label":"First detail","kind":"detail","startLine":1,"endLine":1},{"label":"Second detail","kind":"detail","startLine":1,"endLine":1},{"label":"Third detail","kind":"detail","startLine":1,"endLine":1}]}"#,
        #"{"version":1,"title":"T","summary":"Direct result.","points":[],"details":[{"label":"one two three four five","kind":"detail","startLine":1,"endLine":1}]}"#,
    ])
    func enforcesFieldBounds(json: String) {
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try decode(json)
        }
    }

    @Test("All visible strings share the source-relative character budget")
    func enforcesTotalVisibleBudget() {
        let compactSource = String(repeating: "a", count: 200)
        let json = #"{"version":1,"title":"Undisplayed compatibility title","summary":"123456789012345678901234567890","points":[{"text":"123456789012345","startLine":1,"endLine":1}],"details":[{"label":"123456","kind":"detail","startLine":1,"endLine":1}]}"#

        #expect(throws: ResponseBriefValidationError.notConcise) {
            try ResponseBrief.decodeValidated(Data(json.utf8), source: compactSource)
        }
    }

    @Test("Quarter-size character boundary accepts the limit and rejects one more scalar")
    func quarterCharacterBoundary() throws {
        let compactSource = String(repeating: "a", count: 200)
        let accepted = ResponseBrief(
            version: 1,
            title: "T",
            summary: String(repeating: "b", count: 50),
            points: [],
            details: []
        )
        let rejected = ResponseBrief(
            version: 1,
            title: "T",
            summary: String(repeating: "b", count: 51),
            points: [],
            details: []
        )
        let policy = ResponseBriefConcisionPolicy(source: compactSource)

        try policy.validate(accepted)
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try policy.validate(rejected)
        }
    }

    @Test("Quarter-size word boundary accepts the limit and rejects one more word")
    func quarterWordBoundary() throws {
        let source = (1...80).map { "source\($0)" }.joined(separator: " ")
        let accepted = ResponseBrief(
            version: 1,
            title: "T",
            summary: Array(repeating: "ok", count: 20).joined(separator: " "),
            points: [],
            details: []
        )
        let rejected = ResponseBrief(
            version: 1,
            title: "T",
            summary: Array(repeating: "ok", count: 21).joined(separator: " "),
            points: [],
            details: []
        )
        let policy = ResponseBriefConcisionPolicy(source: source)

        #expect(policy.metrics.maximumVisibleWords == 20)
        try policy.validate(accepted)
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try policy.validate(rejected)
        }
    }

    @Test("The absolute word cap rejects 41 tiny words for a long source")
    func absoluteWordCap() throws {
        let source = Array(repeating: "source", count: 200).joined(separator: " ")
        let accepted = ResponseBrief(
            version: 1,
            title: "T",
            summary: Array(repeating: "a", count: 40).joined(separator: " "),
            points: [],
            details: []
        )
        let rejected = ResponseBrief(
            version: 1,
            title: "T",
            summary: Array(repeating: "a", count: 41).joined(separator: " "),
            points: [],
            details: []
        )
        let policy = ResponseBriefConcisionPolicy(source: source)

        #expect(policy.metrics.maximumVisibleWords == 40)
        #expect(ResponseBriefConcisionPolicy.nonWhitespaceScalarCount(rejected.summary) == 41)
        #expect(ResponseBriefConcisionPolicy.nonWhitespaceScalarCount(rejected.summary) < policy.metrics.maximumVisibleCharacters)
        try policy.validate(accepted)
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try policy.validate(rejected)
        }
    }

    @Test("Output counting includes punctuation, emoji, and combining scalars but ignores markup-only words")
    func unicodeOutputCounting() {
        let visible = "--- 🪻 e\u{301} 東京"

        #expect(ResponseBriefConcisionPolicy.wordCount(visible) == 2)
        #expect(ResponseBriefConcisionPolicy.nonWhitespaceScalarCount(visible) == 8)
    }

    @Test("Generated title is retained for compatibility but excluded from visible budget")
    func titleIsNotVisibleBudget() throws {
        let compactSource = String(repeating: "a", count: 200)
        let title = String(repeating: "T", count: 100)
        let json = "{\"version\":1,\"title\":\"\(title)\",\"summary\":\"Direct result.\",\"points\":[],\"details\":[]}"

        let brief = try ResponseBrief.decodeValidated(Data(json.utf8), source: compactSource)

        #expect(brief.title == title)
        #expect(brief.visibleGeneratedStrings == ["Direct result."])
    }

    @Test("Explicit presets scale the legacy ceilings by exactly two and three")
    func explicitPresetMultipliers() {
        let source = String(repeating: "a", count: 200)
        #expect(ResponseBriefConcisionPolicy(source: source).metrics.maximumVisibleCharacters == 50)
        #expect(ResponseBriefConcisionPolicy(source: source, length: .minimal).metrics.maximumVisibleCharacters == 50)
        #expect(ResponseBriefConcisionPolicy(source: source, length: .medium).metrics.maximumVisibleCharacters == 100)
        #expect(ResponseBriefConcisionPolicy(source: source, length: .long).metrics.maximumVisibleCharacters == 150)

        let wordy = Array(repeating: "ab", count: 200).joined(separator: " ")
        #expect(ResponseBriefConcisionPolicy(source: wordy).metrics.maximumVisibleWords == 40)
        #expect(ResponseBriefConcisionPolicy(source: wordy, length: .minimal).metrics.maximumVisibleWords == 40)
        #expect(ResponseBriefConcisionPolicy(source: wordy, length: .medium).metrics.maximumVisibleWords == 80)
        #expect(ResponseBriefConcisionPolicy(source: wordy, length: .long).metrics.maximumVisibleWords == 120)
    }

    @Test("Explicit minimal preserves legacy ceilings for previously eligible sources")
    func explicitMinimalPreservesLegacyCeilings() {
        let sources = [
            String(repeating: "a", count: 161),
            Array(repeating: "ab", count: 200).joined(separator: " "),
            String(repeating: "界", count: 500),
        ]
        for source in sources {
            let legacy = ResponseBriefConcisionPolicy(source: source).metrics
            let minimal = ResponseBriefConcisionPolicy(source: source, length: .minimal).metrics
            #expect(legacy.shouldGenerate)
            #expect(minimal.maximumVisibleCharacters == legacy.maximumVisibleCharacters)
            #expect(minimal.maximumVisibleWords == legacy.maximumVisibleWords)
        }
    }

    @Test("Tiny sources become eligible with a usable budget and no minimum output")
    func tinySourcesGetUsableBudget() throws {
        for source in ["a", "🪻🪻🪻", String(repeating: "b", count: 160)] {
            let policy = ResponseBriefConcisionPolicy(source: source, length: .minimal)
            #expect(policy.metrics.shouldGenerate)
            #expect(policy.metrics.maximumVisibleCharacters == 40)
            #expect(policy.metrics.maximumVisibleWords == 40)
            try policy.validate(ResponseBrief(version: 1, title: "T", summary: "Done.", points: [], details: []))
        }
        #expect(!ResponseBriefConcisionPolicy(source: "a").metrics.shouldGenerate)
        #expect(!ResponseBriefConcisionPolicy(source: "   \n").metrics.shouldGenerate)
        #expect(!ResponseBriefConcisionPolicy(source: "   \n", length: .minimal).metrics.shouldGenerate)
    }

    @Test("Explicit minimal accepts forty visible scalars for a one-character source and rejects forty-one")
    func minimalTinyBoundary() throws {
        let accepted = briefJSON(summary: String(repeating: "b", count: 40))
        let rejected = briefJSON(summary: String(repeating: "b", count: 41))

        _ = try ResponseBrief.decodeValidated(Data(accepted.utf8), source: "a", length: .minimal)
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try ResponseBrief.decodeValidated(Data(rejected.utf8), source: "a", length: .minimal)
        }
        // The same output stays ineligible under the legacy no-selection path.
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try ResponseBrief.decodeValidated(Data(accepted.utf8), source: "a")
        }
    }

    @Test("Long budgets are attainable inside the structural string bounds")
    func longBudgetIsAttainable() throws {
        #expect(ResponseBriefLength.maximumVisibleCharacters == 720)
        #expect(ResponseBriefLength.maximumVisibleWords == 120)
        #expect(ResponseBriefLength.maximumVisibleCharacters <= ResponseBriefLimits.maximumSummaryCharacters)

        let source = String(repeating: "z", count: 3_000)
        let summary = Array(repeating: "aaaaaaa", count: 100).joined(separator: " ")
        let point = Array(repeating: "b", count: 12).joined(separator: " ")
        let firstLabel = Array(repeating: "c", count: 4).joined(separator: " ")
        let secondLabel = Array(repeating: "d", count: 4).joined(separator: " ")
        let json = """
        {"version":1,"title":"Boundary","summary":"\(summary)","points":[{"text":"\(point)","startLine":1,"endLine":1}],"details":[{"label":"\(firstLabel)","kind":"detail","startLine":1,"endLine":1},{"label":"\(secondLabel)","kind":"table","startLine":1,"endLine":1}]}
        """
        #expect(summary.count <= ResponseBriefLimits.maximumSummaryCharacters)

        let brief = try ResponseBrief.decodeValidated(Data(json.utf8), source: source, length: .long)
        let visible = brief.visibleGeneratedStrings.joined(separator: " ")
        #expect(ResponseBriefConcisionPolicy.nonWhitespaceScalarCount(visible) == 720)
        #expect(ResponseBriefConcisionPolicy.wordCount(visible) == 120)
        #expect(throws: ResponseBriefValidationError.notConcise) {
            try ResponseBrief.decodeValidated(Data(json.utf8), source: source, length: .medium)
        }
    }

    @Test("Swift explicit length policy matches the shared Python fixture corpus")
    func sharedLengthPolicyParity() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(path: "tests/fixtures/response_brief_lengths.json"))
        let fixtures = try JSONDecoder().decode([ResponseBriefLengthFixture].self, from: data)

        #expect(!fixtures.isEmpty)
        #expect(Set(fixtures.map(\.length)) == Set(ResponseBriefLength.options))
        for fixture in fixtures {
            let length = try #require(ResponseBriefLength(rawValue: fixture.length))
            let metrics = ResponseBriefConcisionPolicy(source: fixture.source, length: length).metrics
            #expect(metrics.readableCharacters == fixture.readableCharacters)
            #expect(metrics.sourceWords == fixture.sourceWords)
            #expect(metrics.maximumVisibleCharacters == fixture.maximumVisibleCharacters)
            #expect(metrics.maximumVisibleWords == fixture.maximumVisibleWords)
        }
    }

    @Test("Swift concision policy matches the shared Python fixture corpus")
    func sharedPolicyParity() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(path: "tests/fixtures/response_brief_policy.json"))
        let fixtures = try JSONDecoder().decode([ResponseBriefPolicyFixture].self, from: data)

        for fixture in fixtures {
            let metrics = ResponseBriefConcisionPolicy(source: fixture.source).metrics
            #expect(metrics.readableCharacters == fixture.readableCharacters)
            #expect(metrics.sourceWords == fixture.sourceWords)
            #expect(metrics.maximumVisibleCharacters == fixture.maximumVisibleCharacters)
            #expect(metrics.maximumVisibleWords == fixture.maximumVisibleWords)
            #expect(metrics.shouldGenerate == fixture.shouldGenerate)
        }
    }

    @Test("Output larger than 32 KiB is rejected before parsing")
    func rejectsOversizeOutput() {
        let data = Data(repeating: 0x20, count: ResponseBriefLimits.maximumOutputBytes + 1)
        #expect(throws: ResponseBriefValidationError.outputTooLarge) {
            try ResponseBrief.decodeValidated(data, source: source)
        }
    }

    private func decode(_ json: String) throws -> ResponseBrief {
        try ResponseBrief.decodeValidated(Data(json.utf8), source: source)
    }

    private func briefJSON(summary: String) -> String {
        "{\"version\":1,\"title\":\"T\",\"summary\":\"\(summary)\",\"points\":[],\"details\":[]}"
    }
}

private struct ResponseBriefPolicyFixture: Decodable {
    let name: String
    let source: String
    let readableCharacters: Int
    let sourceWords: Int
    let maximumVisibleCharacters: Int
    let maximumVisibleWords: Int
    let shouldGenerate: Bool
}

private struct ResponseBriefLengthFixture: Decodable {
    let name: String
    let source: String
    let length: String
    let readableCharacters: Int
    let sourceWords: Int
    let maximumVisibleCharacters: Int
    let maximumVisibleWords: Int
}
