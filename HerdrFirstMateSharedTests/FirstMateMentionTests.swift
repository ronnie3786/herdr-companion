import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate mentions")
struct FirstMateMentionTests {
    private let receipts = FirstMateMentionCandidate(name: "Receipt export", target: .feature(featureID: "fmf_receipts"))
    private let receiptsShort = FirstMateMentionCandidate(name: "Receipt", target: .feature(featureID: "fmf_other"))
    private let deviceQA = FirstMateMentionCandidate(
        name: "Device QA", target: .agent(featureID: "fmf_receipts", assignmentID: "as_9")
    )

    // MARK: Wire format

    @Test("Feature and agent URLs round-trip through the parser")
    func urlRoundTrip() throws {
        let feature = FirstMateMention.url(for: .feature(featureID: "fm_123"))
        #expect(feature.absoluteString == "herdr://first-mate?feature_id=fm_123")
        #expect(FirstMateMention.parse(feature) == .feature(featureID: "fm_123"))

        let agent = FirstMateMention.url(for: .agent(featureID: "fm_123", assignmentID: "as_9"))
        #expect(agent.absoluteString == "herdr://first-mate?feature_id=fm_123&assignment_id=as_9")
        #expect(FirstMateMention.parse(agent) == .agent(featureID: "fm_123", assignmentID: "as_9"))

        let unusual = FirstMateMentionTarget.agent(featureID: "fm:a.b-c_d", assignmentID: "as 9&x=1")
        #expect(FirstMateMention.parse(FirstMateMention.url(for: unusual)) == unusual)
    }

    @Test("Parsing is lenient about extra keys and case but needs a feature")
    func lenientParse() throws {
        func parse(_ string: String) throws -> FirstMateMentionTarget? {
            FirstMateMention.parse(try #require(URL(string: string)))
        }
        #expect(try parse("herdr://first-mate?feature_id=f1&server_url=https://example.invalid&tab=agents") == .feature(featureID: "f1"))
        #expect(try parse("HERDR://First-Mate/?assignment_id=a1&feature_id=f1") == .agent(featureID: "f1", assignmentID: "a1"))
        #expect(try parse("herdr://first-mate?feature_id=f1&assignment_id=") == .feature(featureID: "f1"))
        #expect(try parse("herdr://first-mate?assignment_id=a1") == nil)
        #expect(try parse("herdr://first-mate?feature_id=") == nil)
        #expect(try parse("herdr://first-mate") == nil)
        #expect(try parse("herdr://pane?feature_id=f1") == nil)
        #expect(try parse("https://first-mate?feature_id=f1") == nil)
        #expect(try parse("herdr://first-mate/features/f1?feature_id=f1") == nil)
        #expect(try parse("herdr-skim://anchor/a1") == nil)
    }

    @Test("Markdown links escape brackets and backslashes in the name")
    func markdownEscaping() {
        #expect(FirstMateMention.markdownLink(name: "Receipt export", target: .feature(featureID: "f1"))
            == "[Receipt export](herdr://first-mate?feature_id=f1)")
        #expect(FirstMateMention.markdownLink(name: #"Fix [beta] \ cleanup"#, target: .agent(featureID: "f1", assignmentID: "a1"))
            == #"[Fix \[beta\] \\ cleanup](herdr://first-mate?feature_id=f1&assignment_id=a1)"#)
    }

    // MARK: Plain names

    private func names(_ text: String, _ candidates: [FirstMateMentionCandidate]) -> [String] {
        FirstMateMention.plainNameMatches(in: text, candidates: candidates).map { String(text[$0.range]) }
    }

    @Test("Only whole, case-sensitive words match")
    func wholeWords() {
        let candidates = [receiptsShort, deviceQA]
        #expect(names("Receipt is ready. Receipts are not. receipt is lowercase. PreReceipt is glued.", candidates) == ["Receipt"])
        #expect(names("Device QAs and Device QA_2 do not match, but Device QA does.", candidates) == ["Device QA"])
        #expect(names("Numbers glue too: 2Receipt and Receipt2.", candidates) == [])
    }

    @Test("Punctuation around a name is a boundary")
    func punctuationBoundaries() {
        let text = "(Receipt export), \"Receipt export\". Receipt export's owner: Receipt export! Receipt export?"
        let matches = FirstMateMention.plainNameMatches(in: text, candidates: [receipts])
        #expect(matches.count == 5)
        #expect(matches.allSatisfy { $0.target == .feature(featureID: "fmf_receipts") && $0.name == "Receipt export" })
    }

    @Test("Longer names win, and matches never overlap")
    func longestFirstAndOverlaps() {
        let text = "Receipt export shipped; the Receipt screen stayed."
        let matches = FirstMateMention.plainNameMatches(in: text, candidates: [receiptsShort, receipts])
        #expect(matches.map(\.name) == ["Receipt export", "Receipt"])
        #expect(matches.map(\.target) == [.feature(featureID: "fmf_receipts"), .feature(featureID: "fmf_other")])

        let overlapping = [
            FirstMateMentionCandidate(name: "Offline sync", target: .feature(featureID: "a")),
            FirstMateMentionCandidate(name: "sync engine", target: .feature(featureID: "b")),
        ]
        #expect(names("Offline sync engine", overlapping) == ["Offline sync"])
        let duplicate = [receipts, FirstMateMentionCandidate(name: "Receipt export", target: .feature(featureID: "dup"))]
        #expect(FirstMateMention.plainNameMatches(in: "Receipt export", candidates: duplicate).map(\.target) == [.feature(featureID: "fmf_receipts")])
    }

    @Test("Names inside inline code never match")
    func inlineCode() {
        #expect(names("Run `Receipt export` then ``a `Receipt export` b`` and Receipt export.", [receipts]).count == 1)
        #expect(names("An unclosed `Receipt export mention still counts.", [receipts]) == ["Receipt export"])
    }

    @Test("Names inside fenced code blocks never match")
    func fencedCode() {
        let text = """
        Before Receipt export.
        ```swift
        let name = "Receipt export"
        ```
        ~~~
        Receipt export
        ~~~
        After Receipt export.
        ```
        Receipt export in an unclosed fence
        """
        let matches = FirstMateMention.plainNameMatches(in: text, candidates: [receipts])
        #expect(matches.count == 2)
        #expect(text[matches[0].range.lowerBound...].hasPrefix("Receipt export."))
        #expect(text[..<matches[1].range.lowerBound].hasSuffix("After "))
    }

    @Test("Existing links and URLs are left alone")
    func existingLinks() {
        let text = """
        See [Receipt export](herdr://first-mate?feature_id=fmf_receipts), [notes on Receipt export](https://example.invalid/a), \
        <https://example.invalid/Receipt export>, https://example.invalid/Receipt_export and plain Receipt export.
        """
        #expect(names(text, [receipts]) == ["Receipt export"])
        #expect(names("[Fix \\] Receipt export](https://example.invalid) Receipt export", [receipts]).count == 1)
    }

    @Test("Emoji and non-Latin names match with the right boundaries")
    func unicodeNames() {
        let candidates = [
            FirstMateMentionCandidate(name: "🧾 Receipts", target: .feature(featureID: "emoji")),
            FirstMateMentionCandidate(name: "Café sync", target: .feature(featureID: "cafe")),
            FirstMateMentionCandidate(name: "検索", target: .feature(featureID: "search")),
            FirstMateMentionCandidate(name: "Ship 🚀", target: .feature(featureID: "ship")),
        ]
        #expect(names("x🧾 Receipts, Café sync, Café syncs, 検索 and 全検索, Ship 🚀now", candidates)
            == ["🧾 Receipts", "Café sync", "検索", "Ship 🚀"])
    }

    @Test("Blank names are ignored")
    func blankNames() {
        let blank = FirstMateMentionCandidate(name: " ", target: .feature(featureID: "blank"))
        #expect(FirstMateMention.plainNameMatches(in: "a b c", candidates: [blank]).isEmpty)
        #expect(FirstMateMention.plainNameMatches(in: "", candidates: [receipts]).isEmpty)
    }

    // MARK: Composer

    @Test("Picked @names become Markdown links; everything else stays text")
    func composerSerialization() {
        let text = "Can @Device QA retry @Receipt export? Email me@example.invalid, keep `@Device QA` and @Unknown."
        let serialized = FirstMateMention.serializeComposer(text, picks: [deviceQA, receipts])
        #expect(serialized == "Can [Device QA](herdr://first-mate?feature_id=fmf_receipts&assignment_id=as_9) retry "
            + "[Receipt export](herdr://first-mate?feature_id=fmf_receipts)? Email me@example.invalid, keep `@Device QA` and @Unknown.")
        #expect(FirstMateMention.serializeComposer("No picks @Receipt export", picks: []) == "No picks @Receipt export")
    }

    @Test("A longer pick wins over a shorter pick it begins with")
    func composerLongestFirst() {
        let serialized = FirstMateMention.serializeComposer("@Receipt export and @Receipt and @Receipts", picks: [receiptsShort, receipts])
        #expect(serialized == "[Receipt export](herdr://first-mate?feature_id=fmf_receipts) and "
            + "[Receipt](herdr://first-mate?feature_id=fmf_other) and @Receipts")
    }

    @Test("A serialized mention parses back to its pick")
    func composerRoundTrip() throws {
        let serialized = FirstMateMention.serializeComposer("@Device QA", picks: [deviceQA])
        let start = try #require(serialized.range(of: "](")?.upperBound)
        let url = try #require(URL(string: String(serialized[start..<serialized.index(before: serialized.endIndex)])))
        #expect(FirstMateMention.parse(url) == deviceQA.target)
    }
}
