import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Response brief validation")
struct ResponseBriefValidationTests {
    private let source = "first\r\n\n```swift\nlet value = 1\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |"

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
            source: exact
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

    @Test("Summary grammar enforces item and word bounds")
    func enforcesBounds() {
        let words = Array(repeating: "word", count: 141).joined(separator: " ")
        let json = "{\"version\":1,\"title\":\"T\",\"summary\":\"\(words)\",\"points\":[],\"details\":[]}"
        #expect(throws: ResponseBriefValidationError.tooManyWords) {
            try decode(json)
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
}
