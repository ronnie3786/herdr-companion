import CryptoKit
import Foundation

/// A ready skim checked against the exact reply it summarizes, plus the
/// verbatim-excerpt helpers every client uses. `init` fails for anything that
/// cannot be trusted (unknown versions, a different reply, offsets outside the
/// text, dangling ids), and callers then show the full reply unchanged.
struct FirstMateSkimReader: Equatable, Sendable {
    static let segmenterVersion = 1
    static let skimVersion = 1

    let document: SkimDocument
    let segments: [SkimSegment]
    /// The reply with line endings canonicalized to LF, as the companion segmented it.
    let canonicalText: String
    private let texts: [String: String]
    private let index: [String: Int]

    init?(skim: FirstMateSkim?, reply: String) {
        guard let skim, skim.status == .ready,
              skim.segmenterVersion.map({ $0 == Self.segmenterVersion }) ?? true,
              skim.skimVersion.map({ $0 == Self.skimVersion }) ?? true,
              let document = skim.document, document.version == Self.skimVersion,
              let segments = skim.segments, !segments.isEmpty else { return nil }
        let canonical = Self.canonicalize(reply)
        if let expected = skim.replySHA256 {
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else { return nil }
        }
        let units = Array(canonical.utf16)
        var texts: [String: String] = [:]
        var index: [String: Int] = [:]
        for (position, segment) in segments.enumerated() {
            guard segment.id == "s\(position + 1)", segment.n == position + 1,
                  segment.start >= 0, segment.start <= segment.end, segment.end <= units.count,
                  segment.startLine >= 1, segment.startLine <= segment.endLine else { return nil }
            texts[segment.id] = String(decoding: units[segment.start..<segment.end], as: UTF16.self)
            index[segment.id] = position
        }
        let referenced = document.anchors.flatMap(\.refs) + document.rest.refs + document.drawers.flatMap(\.refs)
        guard referenced.allSatisfy({ index[$0] != nil }) else { return nil }
        let anchorIDs = Set(document.anchors.map(\.id))
        guard Self.anchorIDs(in: document).allSatisfy(anchorIDs.contains) else { return nil }
        self.document = document
        self.segments = segments
        self.canonicalText = canonical
        self.texts = texts
        self.index = index
        // A skim with no sentence and no next step would hide the reply.
        guard !sentence.isEmpty || !nextSteps.isEmpty else { return nil }
    }

    /// The reader for one reply, built once: views re-render often, and
    /// validation hashes and slices the whole reply. `owner` is the message
    /// or HUD turn id; a ready skim never changes for the same reply.
    static func cached(skim: FirstMateSkim?, reply: String, owner: String) -> FirstMateSkimReader? {
        guard let skim, skim.status == .ready else { return nil }
        let parts: [String] = [
            owner, skim.replySHA256 ?? "", skim.promptVersion ?? "",
            String(skim.segments?.count ?? 0), String(skim.document?.anchors.count ?? 0),
            String(reply.utf16.count), String(reply.hashValue),
        ]
        let key = NSString(string: parts.joined(separator: "\u{0}"))
        if let entry = readerCache.object(forKey: key) { return entry.reader }
        let reader = FirstMateSkimReader(skim: skim, reply: reply)
        readerCache.setObject(CachedReader(reader), forKey: key)
        return reader
    }

    private final class CachedReader: @unchecked Sendable {
        let reader: FirstMateSkimReader?
        init(_ reader: FirstMateSkimReader?) { self.reader = reader }
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private static let readerCache: NSCache<NSString, CachedReader> = {
        let cache = NSCache<NSString, CachedReader>()
        cache.countLimit = 256
        return cache
    }()

    static func canonicalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func anchorIDs(in document: SkimDocument) -> [String] {
        func ids(_ tokens: [SkimToken]) -> [String] {
            tokens.flatMap { token -> [String] in
                if case .anchor(let id, let label, _) = token { return [id] + ids(label) }
                return []
            }
        }
        return ids(document.headline) + document.blocks.flatMap { block -> [String] in
            switch block {
            case .line(_, let tokens): ids(tokens)
            case .list(let items): items.flatMap(ids)
            }
        }
    }

    // MARK: - One breath (SPEC section 7)

    /// The linked sentence: the headline and every prose block, in order.
    var sentence: [SkimToken] {
        var tokens: [SkimToken] = []
        func append(_ part: [SkimToken]) {
            guard !part.isEmpty else { return }
            if !tokens.isEmpty { tokens.append(.text(" ")) }
            tokens.append(contentsOf: part)
        }
        append(document.headline)
        for block in document.blocks {
            switch block {
            case .line(let kind, let lineTokens) where !Self.tailKinds.contains(kind) && kind != "heads_up":
                append(lineTokens)
            case .list(let items):
                append(Array(items.enumerated().map { offset, item in offset == 0 ? item : [.text("; ")] + item }.joined()))
            default:
                break
            }
        }
        return tokens
    }

    /// Caveat lines: a failure or a real risk only.
    var caveats: [[SkimToken]] {
        document.blocks.compactMap { block in
            if case .line("heads_up", let tokens) = block { return tokens }
            return nil
        }
    }

    enum NextStep: Equatable, Sendable {
        /// A labeled "Next" statement (One breath B).
        case next([SkimToken])
        /// The suggested next step as a question (the default).
        case ask([SkimToken])
    }

    /// The agent's suggested next step, always the message's last line.
    var nextSteps: [NextStep] {
        let nexts = document.blocks.compactMap { block -> NextStep? in
            if case .line("next", let tokens) = block { return .next(tokens) }
            return nil
        }
        let asks = document.blocks.compactMap { block -> NextStep? in
            if case .line("ask", let tokens) = block { return .ask(tokens) }
            return nil
        }
        return nexts + asks
    }

    /// Suggested reply labels (One breath C); plain text by construction.
    var replies: [String] {
        document.blocks.compactMap { block in
            if case .line("reply", let tokens) = block { return tokens.map(\.plainText).joined() }
            return nil
        }
    }

    private static let tailKinds: Set<String> = ["next", "ask", "reply"]

    /// Content blocks the skim doesn't link to, plus each one's section heading for context.
    var restRefs: [String] {
        var refs = Set<String>()
        for id in document.rest.refs {
            guard let segment = segment(id) else { continue }
            if let section = segment.section, section != segment.id { refs.insert(section) }
            refs.insert(id)
        }
        return refs.sorted { order($0) < order($1) }
    }

    var restCount: Int { document.rest.refs.count }

    var restPeek: String {
        "\(restCount) block\(restCount == 1 ? "" : "s") the skim doesn't link to"
    }

    // MARK: - Lookup

    func anchor(_ id: String) -> SkimAnchor? { document.anchors.first { $0.id == id } }

    func segment(_ id: String) -> SkimSegment? { index[id].map { segments[$0] } }

    func text(of id: String) -> String { texts[id] ?? "" }

    private func order(_ id: String) -> Int { index[id] ?? .max }

    /// Code or tables get the wide popover.
    func isWide(_ refs: [String]) -> Bool {
        refs.contains { ["code", "table"].contains(segment($0)?.kind ?? "") }
    }

    func words(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Verbatim excerpts

    /// Exact original text for segment ids. Blocks separated only by rules
    /// read as one run; a real gap starts a new run.
    func runs(for refs: [String]) -> [SkimExcerptRun] {
        let chosen = Set(refs).compactMap(segment).sorted { $0.n < $1.n }
        var groups: [[SkimSegment]] = []
        for segment in chosen {
            if let previous = groups.last?.last,
               segments[previous.n..<(segment.n - 1)].allSatisfy({ $0.kind == "rule" }) {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        let units = Array(canonicalText.utf16)
        return groups.enumerated().map { offset, group in
            let first = group[0], last = group[group.count - 1]
            let skipped = offset == 0 ? nil : first.n - groups[offset - 1].last!.n - 1
            return SkimExcerptRun(ids: group.map(\.id), startLine: first.startLine, endLine: last.endLine,
                                  text: String(decoding: units[first.start..<last.end], as: UTF16.self),
                                  skippedBefore: skipped)
        }
    }

    func lineLabel(for refs: [String]) -> String {
        let found = refs.compactMap(segment)
        guard let first = found.map(\.startLine).min(), let last = found.map(\.endLine).max() else { return "" }
        return first == last ? "Line \(first)" : "Lines \(first)–\(last)"
    }

    /// Copy: the exact canonical text of each run, joined by a blank line.
    func copyText(for refs: [String]) -> String {
        runs(for: refs).map(\.text).joined(separator: "\n\n")
    }

    // MARK: - Hover preview (SPEC section 5)

    func preview(for refs: [String], kind: String) -> SkimPreview {
        let found = refs.compactMap(segment).sorted { $0.n < $1.n }
        let label = lineLabel(for: refs)
        let word = ["code": "Code", "table": "Table"][kind] ?? "Text"
        guard let first = found.first else { return SkimPreview(kindWord: word, lineLabel: label, blockCount: 0, body: .text("")) }
        let body: SkimPreview.Body
        if first.kind == "code" {
            body = .code(codePreview(first))
        } else if first.kind == "table" {
            body = .table(text(of: first.id).components(separatedBy: "\n").prefix(6).joined(separator: "\n"))
        } else if let code = found.first(where: { $0.kind == "code" }), (first.words ?? words(of: text(of: first.id))) < 25 {
            // A short lead-in followed by code: the code is what the reader wants to see.
            body = .leadIn(Self.leadIn(text(of: first.id)), codePreview(code))
        } else {
            body = .text(Self.flatten(text(of: first.id)))
        }
        return SkimPreview(kindWord: word, lineLabel: label, blockCount: found.count, body: body)
    }

    func codePreview(_ segment: SkimSegment) -> SkimCodePreview {
        let code = Self.codeBody(text(of: segment.id))
        let view = SkimCodeLanguage.previewLines(code, language: segment.lang)
        return SkimCodePreview(language: SkimCodeLanguage.label(segment.lang, code: code), languageKey: segment.lang ?? "",
                               totalLines: view.total, fromLine: view.from, lines: view.lines,
                               moreLines: max(0, view.total - view.lines.count))
    }

    /// The code inside a fenced block, without its fences or their indentation.
    static func codeBody(_ fenced: String) -> String {
        var lines = fenced.components(separatedBy: "\n")
        guard let opening = lines.first else { return "" }
        let indent = opening.prefix { $0 == " " }.count
        lines.removeFirst()
        if let last = lines.last, last.range(of: #"^\s*(`{3,}|~{3,})\s*$"#, options: .regularExpression) != nil {
            lines.removeLast()  // An unterminated fence keeps its last line.
        }
        return lines.map { line in
            let strip = min(indent, line.prefix { $0 == " " }.count)
            return String(line.dropFirst(strip))
        }.joined(separator: "\n")
    }

    static func flatten(_ text: String, limit: Int = 220) -> String {
        var value = text
        for (pattern, template) in [
            (#"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, ""), (#"(?m)^#+\s*"#, ""), (#"[*_`]"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"), (#"\s+"#, " "),
        ] {
            value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        let cut = String(value.prefix(limit)).replacingOccurrences(of: #"\s+\S*$"#, with: "", options: .regularExpression)
        return cut + "…"
    }

    static func leadIn(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:[-+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SkimExcerptRun: Equatable, Sendable, Identifiable {
    var ids: [String]
    var startLine: Int
    var endLine: Int
    var text: String
    /// Blocks between the previous run and this one; nil for the first run.
    var skippedBefore: Int?
    var id: String { ids.first ?? "" }

    var gapLabel: String? {
        guard let skippedBefore else { return nil }
        return skippedBefore > 0 ? "\(skippedBefore) block\(skippedBefore == 1 ? "" : "s") skipped" : "Skipped"
    }
}

struct SkimPreview: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case text(String)
        case table(String)
        case code(SkimCodePreview)
        case leadIn(String, SkimCodePreview)
    }

    var kindWord: String
    var lineLabel: String
    var blockCount: Int
    var body: Body

    var isWide: Bool {
        switch body {
        case .text: false
        case .table, .code, .leadIn: true
        }
    }
}

struct SkimCodePreview: Equatable, Sendable {
    var language: String
    var languageKey: String
    var totalLines: Int
    var fromLine: Int?
    var lines: [String]
    var moreLines: Int

    var header: String {
        var parts = [language, "\(totalLines) line\(totalLines == 1 ? "" : "s")"]
        if let fromLine { parts.append("from line \(fromLine)") }
        return parts.joined(separator: ", ")
    }
}
