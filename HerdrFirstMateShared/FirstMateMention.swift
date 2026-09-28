import Foundation

/// What a mention points at: a feature's chat, or one crew agent in it.
enum FirstMateMentionTarget: Hashable, Sendable {
    case feature(featureID: String)
    case agent(featureID: String, assignmentID: String)

    var featureID: String {
        switch self {
        case .feature(let featureID), .agent(let featureID, _): featureID
        }
    }
}

/// A name that may be mentioned, and where it points.
struct FirstMateMentionCandidate: Hashable, Sendable {
    var name: String
    var target: FirstMateMentionTarget
}

/// One plain-name mention found in message text.
struct FirstMateMentionMatch: Equatable, Sendable {
    var range: Range<String.Index>
    var name: String
    var target: FirstMateMentionTarget
}

/// Mentions travel as ordinary Markdown links, so iOS, the web, and the
/// coordinator all read `[Receipt export](herdr://first-mate?feature_id=…)`.
///
/// This parser is deliberately separate from `FirstMateOpenRequest`, which
/// validates external deep links and stays strict. A mention only ever selects
/// a chat that is already listed.
enum FirstMateMention {
    static let scheme = "herdr"
    static let host = "first-mate"

    static func url(for target: FirstMateMentionTarget) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: "feature_id", value: target.featureID)]
        if case .agent(_, let assignmentID) = target {
            items.append(URLQueryItem(name: "assignment_id", value: assignmentID))
        }
        components.queryItems = items
        // Built from fixed parts, so it always forms a URL.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Needs `feature_id`; `assignment_id` is optional and every other key is
    /// ignored, so a future field never breaks an older client.
    static func parse(_ url: URL) -> FirstMateMentionTarget? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              ["", "/"].contains(url.path),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let featureID = value("feature_id") else { return nil }
        if let assignmentID = value("assignment_id") {
            return .agent(featureID: featureID, assignmentID: assignmentID)
        }
        return .feature(featureID: featureID)
    }

    /// `[name](herdr://first-mate?…)` with `[`, `]` and `\` escaped in the name.
    static func markdownLink(name: String, target: FirstMateMentionTarget) -> String {
        var escaped = ""
        for character in name {
            if character == "\\" || character == "[" || character == "]" { escaped.append("\\") }
            escaped.append(character)
        }
        return "[\(escaped)](\(url(for: target).absoluteString))"
    }

    // MARK: Plain names

    /// Exact, case-sensitive, whole-word occurrences of candidate names.
    ///
    /// Longer names win over names they contain, matches never overlap, and
    /// nothing inside inline code, fenced code blocks, Markdown links, or bare
    /// URLs is matched. A name that starts or ends with a symbol (such as an
    /// emoji) needs no word boundary on that side.
    static func plainNameMatches(in text: String, candidates: [FirstMateMentionCandidate]) -> [FirstMateMentionMatch] {
        var taken = excludedRanges(in: text)
        var matches: [FirstMateMentionMatch] = []
        for candidate in orderedCandidates(candidates) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: candidate.name, options: [.literal], range: searchStart..<text.endIndex) {
                searchStart = found.upperBound
                guard isWholeWord(found, in: text),
                      !taken.contains(where: { $0.overlaps(found) }) else { continue }
                taken.append(found)
                matches.append(FirstMateMentionMatch(range: found, name: candidate.name, target: candidate.target))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Replaces each `@Name` of a picked candidate with its Markdown link.
    /// Text inside code is left alone, and a longer pick wins over a shorter
    /// one it begins with.
    static func serializeComposer(_ text: String, picks: [FirstMateMentionCandidate]) -> String {
        var taken = excludedRanges(in: text)
        var replacements: [(Range<String.Index>, String)] = []
        for candidate in orderedCandidates(picks) {
            let token = "@" + candidate.name
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: token, options: [.literal], range: searchStart..<text.endIndex) {
                searchStart = found.upperBound
                let nameRange = text.index(after: found.lowerBound)..<found.upperBound
                guard isWholeWord(nameRange, in: text, checkLeading: false),
                      !taken.contains(where: { $0.overlaps(found) }) else { continue }
                taken.append(found)
                replacements.append((found, markdownLink(name: candidate.name, target: candidate.target)))
            }
        }
        var result = text
        for (range, link) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: link)
        }
        return result
    }

    private static func orderedCandidates(_ candidates: [FirstMateMentionCandidate]) -> [FirstMateMentionCandidate] {
        var seen = Set<String>()
        return candidates.enumerated()
            .filter { !$0.element.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.element.name.count == $1.element.name.count ? $0.offset < $1.offset : $0.element.name.count > $1.element.name.count }
            .map(\.element)
            // The first candidate with a name owns it.
            .filter { seen.insert($0.name).inserted }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String, checkLeading: Bool = true) -> Bool {
        let name = text[range]
        if checkLeading, let first = name.first, isWordCharacter(first), range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if let last = name.last, isWordCharacter(last), range.upperBound < text.endIndex,
           isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    /// Fenced code blocks, inline code spans, Markdown links, autolinks, and
    /// bare URLs: text that is never rewritten into a mention.
    static func excludedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        // Fenced blocks: from a line opening with ``` or ~~~ to the line that
        // closes it, or to the end of the text when it never closes.
        var lineStart = text.startIndex
        var openFence: (marker: String, start: String.Index)?
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[lineStart..<lineEnd].drop { $0 == " " }
            if let fence = openFence {
                if trimmed.hasPrefix(fence.marker) {
                    ranges.append(fence.start..<lineEnd)
                    openFence = nil
                }
            } else if trimmed.hasPrefix("```") {
                openFence = ("```", lineStart)
            } else if trimmed.hasPrefix("~~~") {
                openFence = ("~~~", lineStart)
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        if let fence = openFence { ranges.append(fence.start..<text.endIndex) }

        func outsideFences(_ range: Range<String.Index>) -> Bool {
            !ranges.contains { $0.overlaps(range) }
        }
        // Inline code: a run of backticks closed by a run of the same length.
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else { index = text.index(after: index); continue }
            var runEnd = index
            while runEnd < text.endIndex, text[runEnd] == "`" { runEnd = text.index(after: runEnd) }
            let fence = String(text[index..<runEnd])
            if let close = text.range(of: fence, options: [.literal], range: runEnd..<text.endIndex) {
                let span = index..<close.upperBound
                if outsideFences(span) { ranges.append(span) }
                index = close.upperBound
            } else {
                index = runEnd
            }
        }
        for pattern in [#"!?\[(?:\\.|[^\]\\])*\]\([^)\s]*(?:\s+"[^"]*")?\)"#, #"<[A-Za-z][A-Za-z0-9+.-]*:[^>\s]*>"#,
                        #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>()\[\]]+"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for result in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(result.range, in: text) else { continue }
                ranges.append(range)
            }
        }
        return ranges
    }
}
