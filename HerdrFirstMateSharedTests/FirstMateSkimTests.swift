import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate skims")
struct FirstMateSkimTests {
    private func pieces(_ json: String) throws -> (message: FirstMateMessage, reader: FirstMateSkimReader) {
        let message = try FirstMateSkimFixtures.message(json)
        return (message, try #require(FirstMateSkimReader(skim: message.skim, reply: message.text)))
    }

    @Test("A ready skim decodes and lays out as One breath")
    func readySkim() throws {
        let (message, reader) = try pieces(FirstMateSkimFixtures.raceJSON)
        #expect(message.skim?.status == .ready)
        #expect(reader.document.format == "breath_tight")
        let sentence = reader.sentence.map(\.plainText).joined()
        #expect(sentence.hasPrefix("It's not safe today"))
        #expect(reader.caveats.count == 1)
        guard case .ask(let ask) = try #require(reader.nextSteps.last) else {
            Issue.record("The next step should be a question")
            return
        }
        #expect(ask.map(\.plainText).joined().hasSuffix("?"))
        #expect(reader.document.anchors.map(\.id) == reader.document.anchors.indices.map { "a\($0 + 1)" })
        #expect(reader.restCount > 0)
        #expect(reader.restPeek == "\(reader.restCount) block\(reader.restCount == 1 ? "" : "s") the skim doesn't link to")
    }

    @Test("Excerpts are verbatim slices of the reply, never model text")
    func verbatimExcerpts() throws {
        let (message, reader) = try pieces(FirstMateSkimFixtures.centJSON)
        let canonical = FirstMateSkimReader.canonicalize(message.text)
        for anchor in reader.document.anchors {
            let runs = reader.runs(for: anchor.refs)
            #expect(!runs.isEmpty)
            for run in runs {
                #expect(canonical.contains(run.text), "\(anchor.id) sliced text outside the reply")
                #expect(run.startLine <= run.endLine)
            }
            #expect(reader.copyText(for: anchor.refs) == runs.map(\.text).joined(separator: "\n\n"))
            #expect(reader.lineLabel(for: anchor.refs).hasPrefix("Line"))
        }
        for segment in reader.segments {
            #expect(reader.text(of: segment.id) == String(decoding: Array(canonical.utf16)[segment.start..<segment.end], as: UTF16.self))
        }
    }

    @Test("Rest of the original keeps each leftover block's heading")
    func restCarriesHeadings() throws {
        let (_, reader) = try pieces(FirstMateSkimFixtures.centJSON)
        let rest = Set(reader.restRefs)
        for id in reader.document.rest.refs {
            #expect(rest.contains(id))
            if let section = reader.segment(id)?.section { #expect(rest.contains(section)) }
        }
    }

    @Test("Separated runs report how many blocks they skip")
    func gaps() throws {
        let (_, reader) = try pieces(FirstMateSkimFixtures.raceJSON)
        let first = try #require(reader.segments.first { $0.kind != "rule" && $0.kind != "heading" })
        let later = try #require(reader.segments.last { $0.kind == "paragraph" && $0.n > first.n + 2 })
        let runs = reader.runs(for: [later.id, first.id])
        #expect(runs.map(\.ids) == [[first.id], [later.id]])
        #expect(runs[0].gapLabel == nil)
        #expect(runs[1].gapLabel?.hasSuffix("skipped") == true)
    }

    @Test("Pending, failed, rejected, and unknown skims leave the full reply", arguments: ["pending", "failed", "rejected", "sideways"])
    func unusableStatuses(status: String) throws {
        let json = """
        {"id":"m1","feature_id":"f","role":"assistant","text":"A long reply.","status":"done","created_at":"2026-09-26T00:00:00Z",
         "skim":{"status":"\(status)","format":"breath_tight","prompt_version":"skim-v2","segmenter_version":1,"skim_version":1}}
        """
        let message = try FirstMateSkimFixtures.message(json)
        #expect(message.skim != nil)
        #expect(message.skim?.status == (status == "sideways" ? .unknown : FirstMateSkim.Status(rawValue: status)))
        #expect(FirstMateSkimReader(skim: message.skim, reply: message.text) == nil)
    }

    @Test("Older companions and malformed skims never break the message")
    func tolerantDecoding() throws {
        let plain = try FirstMateSkimFixtures.message("""
        {"id":"m1","feature_id":"f","role":"assistant","text":"Hi","status":"done","created_at":"2026-09-26T00:00:00Z"}
        """)
        #expect(plain.skim == nil)
        let malformed = try FirstMateSkimFixtures.message("""
        {"id":"m2","feature_id":"f","role":"assistant","text":"Hi","status":"done","created_at":"2026-09-26T00:00:00Z",
         "skim":{"status":"ready","document":{"version":"x"},"segments":"nope"}}
        """)
        #expect(malformed.skim?.document == nil)
        #expect(FirstMateSkimReader(skim: malformed.skim, reply: malformed.text) == nil)
        let notAnObject = try FirstMateSkimFixtures.message("""
        {"id":"m3","feature_id":"f","role":"assistant","text":"Hi","status":"done","created_at":"2026-09-26T00:00:00Z","skim":"ready"}
        """)
        #expect(notAnObject.skim?.status == .unknown)
        let snapshot = try JSONDecoder().decode(FirstMateSnapshot.self, from: Data("""
        {"ok":true,"feature":{"id":"fmf_synthetic","title":"Synthetic","goal":"Synthetic","cwd":"/tmp/synthetic","status":"running",
         "revision":1,"created_at":"2026-09-26T00:00:00Z","updated_at":"2026-09-26T00:00:00Z"},
         "messages":[\(FirstMateSkimFixtures.txnJSON)],"visits":[],"events":[]}
        """.utf8))
        #expect(snapshot.messages.first?.skim?.status == .ready)
    }

    @Test("A skim for different text, bad offsets, or an unknown version is refused")
    func refusesMismatches() throws {
        let message = try FirstMateSkimFixtures.message(FirstMateSkimFixtures.txnJSON)
        #expect(FirstMateSkimReader(skim: message.skim, reply: message.text + " edited") == nil)
        var shifted = try #require(message.skim)
        shifted.replySHA256 = nil
        shifted.segments?[0].end = message.text.utf16.count + 10
        #expect(FirstMateSkimReader(skim: shifted, reply: message.text) == nil)
        var future = try #require(message.skim)
        future.segmenterVersion = 2
        #expect(FirstMateSkimReader(skim: future, reply: message.text) == nil)
        var dangling = try #require(message.skim)
        dangling.document?.anchors[0].refs = ["s999"]
        #expect(FirstMateSkimReader(skim: dangling, reply: message.text) == nil)
    }

    @Test("CRLF replies slice by their canonical LF text")
    func crlfReplies() throws {
        let message = try FirstMateSkimFixtures.message(FirstMateSkimFixtures.txnJSON)
        let crlf = message.text.replacingOccurrences(of: "\n", with: "\r\n")
        let reader = try #require(FirstMateSkimReader(skim: message.skim, reply: crlf))
        #expect(!reader.runs(for: reader.document.anchors[0].refs)[0].text.contains("\r"))
    }

    @Test("Code previews show real code: language, size, and the lines that matter")
    func codePreview() throws {
        let (_, reader) = try pieces(FirstMateSkimFixtures.raceJSON)
        let code = try #require(reader.segments.first { $0.kind == "code" })
        let preview = reader.codePreview(code)
        #expect(!preview.language.isEmpty)
        #expect(preview.totalLines == (code.codeLines ?? preview.totalLines))
        #expect(preview.lines.count <= 8)
        #expect(!FirstMateSkimReader.codeBody(reader.text(of: code.id)).contains("```"))
        let body = SkimCodeLanguage.previewLines("import a\nimport b\n\nfunc go() {\n  run()\n}", language: "swift")
        #expect(body.from == 4)
        #expect(body.lines.first == "func go() {")
        let diff = SkimCodeLanguage.previewLines("@@ -1 +1 @@\n context\n-old\n+new", language: "diff")
        #expect(diff.lines == ["@@ -1 +1 @@", "-old", "+new"])
    }

    @Test("The highlighter colors tokens and diff lines by UTF-16 range")
    func highlighter() {
        let code = "const total = sum(items) // cents\nreturn \"ok\""
        let spans = SkimCodeHighlighter.spans(code, language: "js")
        let styled = spans.map { span in ((code as NSString).substring(with: NSRange(location: span.location, length: span.length)), span.style) }
        #expect(styled.contains { $0 == ("const", .keyword) })
        #expect(styled.contains { $0 == ("sum", .function) })
        #expect(styled.contains { $0 == ("// cents", .comment) })
        #expect(styled.contains { $0 == ("\"ok\"", .string) })
        let diff = SkimCodeHighlighter.spans("@@ -1 +1 @@\n-old\n+new", language: "diff")
        #expect(diff.map(\.style) == [.hunk, .removed, .added])
        #expect(SkimCodeLanguage.label("js") == "JavaScript")
        #expect(SkimCodeLanguage.label(nil, code: "✓ passes\n✗ fails") == "Output")
    }
}
