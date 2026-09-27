import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_ios

private typealias UnderlineKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
private typealias ForegroundKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
private typealias BackgroundKey = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
private typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute

@Suite("Skim presentation")
@MainActor
struct SkimPresentationTests {
    private var sayTokens: [SkimToken] {
        guard case .line(_, let tokens) = SkimFixture.checkoutDocument.blocks[0] else { return [] }
        return tokens
    }

    // MARK: - Linked text

    @Test("Anchors are dotted links in the text color, never the accent")
    func anchorsKeepTheTextColor() throws {
        let text = SkimText.attributed(sayTokens, style: .hud, color: HerdrTheme.text)
        let linked = text.runs.filter { $0.link != nil }

        #expect(linked.map { String(text[$0.range].characters) } == ["reserves stock first", "a declined card", "checkout()"])
        #expect(linked.compactMap { $0.link.flatMap(SkimText.anchorID(in:)) } == ["a1", "a2", "a3"])
        for run in linked {
            #expect(run[UnderlineKey.self] == Text.LineStyle(pattern: .dot, color: HerdrTheme.text.opacity(0.55)))
            #expect(run[BackgroundKey.self] == nil)
        }
        let phrase = try #require(linked.first)
        #expect(phrase[ForegroundKey.self] == HerdrTheme.text)
        #expect(text.runs.first?[ForegroundKey.self] == HerdrTheme.text)
        #expect(String(text.characters) == "Checkout now reserves stock first, and a declined card releases the hold inside checkout().")
    }

    @Test("The open anchor gets a solid accent underline and a light tint")
    func openAnchor() throws {
        let text = SkimText.attributed(sayTokens, style: .hud, color: HerdrTheme.text, openAnchorID: "a2")
        let open = try #require(text.runs.first { $0.link == SkimText.url(anchorID: "a2") })
        let closed = try #require(text.runs.first { $0.link == SkimText.url(anchorID: "a1") })

        #expect(open[UnderlineKey.self] == Text.LineStyle(pattern: .solid, color: HerdrTheme.accent))
        #expect(open[BackgroundKey.self] == HerdrTheme.accent.opacity(0.17))
        #expect(closed[BackgroundKey.self] == nil)
    }

    @Test("Inline code uses each host's inline code style")
    func inlineCode() throws {
        let hud = SkimText.attributed(sayTokens, style: .hud, color: HerdrTheme.text)
        let hudCode = try #require(hud.runs.first { $0.link == SkimText.url(anchorID: "a3") })
        #expect(hudCode[FontKey.self] != nil)
        #expect(hudCode[ForegroundKey.self] == HerdrProse.inlineCodeColor)

        let style = SkimStyle.firstMate(.dark)
        let firstMate = SkimText.attributed(sayTokens, style: style, color: style.text)
        let firstMateCode = try #require(firstMate.runs.first { $0.link == SkimText.url(anchorID: "a3") })
        #expect(firstMateCode.inlinePresentationIntent == .code)
        #expect(firstMateCode[FontKey.self] == nil)
    }

    @Test("Anchor links round-trip and nothing else is an anchor")
    func anchorURLs() throws {
        let url = try #require(SkimText.url(anchorID: "a12"))
        #expect(url.absoluteString == "herdr-skim://anchor/a12")
        #expect(SkimText.anchorID(in: url) == "a12")
        #expect(SkimText.anchorID(in: try #require(URL(string: "https://example.com/anchor/a1"))) == nil)
        #expect(SkimText.anchorID(in: try #require(URL(string: "herdr-skim://other/a1"))) == nil)
        #expect(SkimText.anchorID(in: try #require(URL(string: "herdr-skim://anchor"))) == nil)
    }

    @Test("Each anchor gets one accessibility action, in reading order")
    func mentions() {
        let tokens: [SkimToken] = [
            .anchor(id: "a1", label: [.text("one")], refs: ["s1"]),
            .text(" and "),
            .anchor(id: "a2", label: [.text("two "), .code("x()")], refs: ["s2"]),
            .anchor(id: "a1", label: [.text("one")], refs: ["s1"]),
        ]
        #expect(SkimText.mentions(in: tokens) == [.init(id: "a1", phrase: "one"), .init(id: "a2", phrase: "two x()")])
    }

    // MARK: - Excerpts

    @Test("A run splits into prose for the Markdown renderer and fenced code for the code block")
    func excerptParts() throws {
        let reader = try #require(SkimFixture.checkoutReader())
        let run = try #require(reader.runs(for: ["s2", "s3"]).first)
        let parts = SkimExcerptPart.split(run.text)

        #expect(parts.count == 2)
        guard case .prose(let prose) = parts.first?.content else {
            Issue.record("Expected prose first")
            return
        }
        #expect(prose.trimmingCharacters(in: .whitespacesAndNewlines) == reader.text(of: "s2"))
        #expect(parts.last?.content == .code(language: "js", code: FirstMateSkimReader.codeBody(reader.text(of: "s3"))))
    }

    @Test("Fences nested in list items, tildes, and unterminated fences become code")
    func excerptFenceVariants() {
        let nested = "1. Switch to a cursor:\n\n   ```js\n   for await (const row of cursor) write(row);\n   ```\n2. Add an index"
        #expect(SkimExcerptPart.split(nested).map(\.content) == [
            .prose("1. Switch to a cursor:\n"),
            .code(language: "js", code: "for await (const row of cursor) write(row);"),
            .prose("2. Add an index"),
        ])
        #expect(SkimExcerptPart.split("~~~sh\nnpm test\n~~~").map(\.content) == [.code(language: "sh", code: "npm test")])
        #expect(SkimExcerptPart.split("```\nstill open").map(\.content) == [.code(language: nil, code: "still open")])
        #expect(SkimExcerptPart.split("Only ``inline`` code here.").map(\.content) == [.prose("Only ``inline`` code here.")])
    }

    @Test("The segmented full reply keeps every segment and any text between them")
    func segmentedChunks() throws {
        let reader = try #require(SkimFixture.checkoutReader())
        let chunks = SkimSegmentedReply.chunks(reader)
        #expect(chunks.map(\.id) == (1...7).map { "s\($0)" })
        #expect(chunks.map(\.text) == (1...7).map { reader.text(of: "s\($0)") })

        let blocks = Array(SkimFixture.checkoutBlocks.prefix(3))
        var segments = SkimFixture.segments(blocks)
        var third = segments[2]
        third.id = "s2"
        third.n = 2
        segments = [segments[0], third]
        let skim = FirstMateSkim(status: .ready, document: SkimDocument(blocks: [.line(kind: "say", tokens: [.text("Synthetic.")])], anchors: []),
                                 segments: segments)
        let partial = try #require(FirstMateSkimReader(skim: skim, reply: SkimFixture.reply(blocks)))
        let withGap = SkimSegmentedReply.chunks(partial)
        #expect(withGap.map(\.id) == ["s1", "gap-before-s2", "s2"])
        #expect(withGap[1].text.trimmingCharacters(in: .whitespacesAndNewlines) == blocks[1].text)
    }

    // MARK: - Code

    @Test("Code lines carry their own spans and whole-line diff tints")
    func codeLines() throws {
        let diff = FirstMateSkimReader.codeBody(SkimFixture.uploadBlocks[1].text)
        let diffLines = SkimCodeLayout.lines(diff, language: "diff")
        #expect(diffLines.map(\.tint) == [nil, .removed, .added, nil])
        #expect(diffLines[0].spans.map(\.style) == [.hunk])

        let js = FirstMateSkimReader.codeBody(SkimFixture.checkoutBlocks[2].text)
        let jsLines = SkimCodeLayout.lines(js, language: "js")
        #expect(jsLines.count == 9)
        #expect(jsLines[0].spans.first == .init(location: 0, length: 5, style: .keyword))
        #expect(jsLines[5].spans.contains { $0.style == .comment })
        for line in jsLines {
            for span in line.spans {
                #expect(span.location >= 0 && span.location + span.length <= line.text.utf16.count)
            }
            #expect(String(SkimCodeLayout.attributed(line, style: .hud).characters) == line.text)
        }

        let log = FirstMateSkimReader.codeBody(SkimFixture.uploadBlocks[3].text)
        #expect(SkimCodeLayout.lines(log, language: nil).map(\.tint) == [.added, .added, nil])
        #expect(SkimCodeLanguage.label(nil, code: log) == "Output")
    }

    @Test("A block comment across lines is split at the line break")
    func multilineComment() {
        let lines = SkimCodeLayout.lines("/* one\ntwo */ let x = 1", language: "js")
        #expect(lines[0].spans.first == .init(location: 0, length: 6, style: .comment))
        #expect(lines[1].spans.first == .init(location: 0, length: 6, style: .comment))
        #expect(lines[1].spans.contains { $0.style == .keyword })
    }

    @Test("Line counts and blank lines")
    func lineCounts() {
        #expect(SkimCodeLayout.lineCountLabel("one") == "1 line")
        #expect(SkimCodeLayout.lineCountLabel("one\n\nthree") == "3 lines")
        #expect(SkimCodeLayout.lineCountLabel("") == "0 lines")
        let blank = SkimCodeLine(id: 0, text: "", spans: [], tint: nil)
        #expect(String(SkimCodeLayout.attributed(blank, style: .hud).characters) == " ")
        #expect(SkimCodeLanguage.label("js", code: "") == "JavaScript")
    }

    // MARK: - State

    @Test("Skim is the default; the toggle and Show in reply are remembered per message")
    func readingState() throws {
        let reader = try #require(SkimFixture.checkoutReader())
        let state = SkimReadingState()
        #expect(!state.showsFullReply("m1"))

        state.toggleFullReply("m1")
        #expect(state.showsFullReply("m1"))
        #expect(!state.showsFullReply("m2"))
        state.toggleFullReply("m1")
        #expect(!state.showsFullReply("m1"))

        state.showInReply(messageID: "m1", refs: ["s3", "s2"], reader: reader)
        #expect(state.showsFullReply("m1"))
        #expect(state.highlights(for: "m1") == ["s2", "s3"])
        #expect(state.scrollRequest == SkimScrollRequest(targetID: "skim-m1-s2", serial: 1))
        state.showInReply(messageID: "m1", refs: ["s2"], reader: reader)
        #expect(state.scrollRequest?.serial == 2)

        state.toggleFullReply("m1")
        #expect(!state.showsFullReply("m1"))
        #expect(state.highlights(for: "m1").isEmpty)

        state.showInReply(messageID: "m3", refs: ["s99"], reader: reader)
        #expect(!state.showsFullReply("m3"))
        #expect(state.scrollRequest?.serial == 2)
    }

    @Test("A newer skim waits until the open excerpt closes")
    func swapWaitsForTheExcerpt() throws {
        let live = try #require(SkimFixture.checkoutReader())
        var olderSkim = SkimFixture.checkoutSkim()
        olderSkim.document?.stats = SkimStats(sourceWords: 1, skimWords: 1)
        let older = try #require(FirstMateSkimReader(skim: olderSkim, reply: SkimFixture.checkoutReply))
        #expect(older != live)

        #expect(SkimDisplay.reader(live: nil, presented: nil) == nil)
        #expect(SkimDisplay.reader(live: live, presented: nil) == live)
        let open = SkimExcerptRequest(reader: older, refs: ["s1"], anchorID: "a1", title: "reserves stock first", source: .sentence)
        #expect(SkimDisplay.reader(live: live, presented: open) == older)
        #expect(SkimDisplay.reader(live: nil, presented: open) == older)
    }

    @Test("A skim with nothing to show falls back to the full reply")
    func emptySkim() throws {
        let skim = FirstMateSkim(status: .ready, document: SkimDocument(blocks: [], anchors: []),
                                 segments: SkimFixture.segments(SkimFixture.checkoutBlocks))
        let reader = try #require(FirstMateSkimReader(skim: skim, reply: SkimFixture.checkoutReply))
        #expect(!SkimDisplay.hasContent(reader))
        #expect(SkimDisplay.reader(live: reader, presented: nil) == nil)
        #expect(FirstMateSkimReader(skim: SkimFixture.checkoutSkim(.pending), reply: SkimFixture.checkoutReply) == nil)
        #expect(FirstMateSkimReader(skim: SkimFixture.checkoutSkim(), reply: SkimFixture.checkoutReply + " edited") == nil)
        #expect(FirstMateSkimReader(skim: SkimFixture.checkoutSkim(hashed: false), reply: SkimFixture.checkoutReply) != nil)
    }
}
