import Foundation

enum WatchersSummary {
    enum Run: Equatable, Sendable {
        case word(String)
        case chip(kind: String, value: String, punctuation: String)
    }
    static let kinds: Set<String> = ["time", "slack", "gh", "skill", "agent", "script", "inbox", "repo", "pc"]
    /// Unknown or malformed markup remains visible prose. A chip and its closing punctuation are indivisible.
    static func parse(_ markup: String, schedule: String = "on a custom schedule") -> [Run] {
        var depth = 0
        for character in markup {
            if character == "{" { depth += 1 }; if character == "}" { depth -= 1 }
            if depth < 0 || depth > 1 { return markup.split(whereSeparator: \.isWhitespace).map { .word(String($0)) } }
        }
        guard depth == 0 else { return markup.split(whereSeparator: \.isWhitespace).map { .word(String($0)) } }
        let expression = try! NSRegularExpression(pattern: #"\{([a-z]+)(?::([^{}]*))?\}([.,;:!?\u2019\u201D)]+)?"#)
        let source = markup as NSString
        var result: [Run] = []; var end = 0
        func words(_ value: String) { result += value.split(whereSeparator: \.isWhitespace).map { .word(String($0)) } }
        for match in expression.matches(in: markup, range: NSRange(location: 0, length: source.length)) {
            words(source.substring(with: NSRange(location: end, length: match.range.location - end)))
            let kind = source.substring(with: match.range(at: 1))
            let value = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            if kinds.contains(kind), kind == "time" || !value.isEmpty {
                var label = kind == "time" ? schedule : value
                let prefix = source.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                if kind == "time", prefix.isEmpty || prefix.last.map({ ".!?".contains($0) }) == true { label = label.prefix(1).uppercased() + label.dropFirst() }
                let punctuation = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                result.append(.chip(kind: kind, value: label, punctuation: punctuation))
            } else { words(source.substring(with: match.range)) }
            end = NSMaxRange(match.range)
        }
        words(source.substring(from: end)); return result
    }
    static func plainText(_ markup: String, schedule: String) -> String {
        parse(markup, schedule: schedule).map { switch $0 { case .word(let value): value; case .chip(_, let value, let punctuation): value + punctuation } }.joined(separator: " ")
    }
}

extension WatchersSummary {
    /// Server validation resolves truthful chip values. Invalid references arrive as text.
    static func parseTokens(_ tokens: [PiJSONValue]) -> [Run] {
        var result: [Run] = []
        var prefix = ""
        for token in tokens {
            guard let value = token.objectValue else { continue }
            if value.text("kind") == "chip", kinds.contains(value.text("chip")) {
                var label = value.text("value")
                let preceding = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.text("chip") == "time", preceding.isEmpty || preceding.last.map({ ".!?".contains($0) }) == true { label = label.prefix(1).uppercased() + label.dropFirst() }
                result.append(.chip(kind: value.text("chip"), value: label, punctuation: ""))
                prefix += label
            } else {
                var text = value.text("text", fallback: value.text("value"))
                prefix += text
                if case let .chip(kind, value, punctuation)? = result.last {
                    let tail = String(text.prefix { ".,;:!?\u{2019}\u{201D})".contains($0) })
                    if !tail.isEmpty { result[result.count - 1] = .chip(kind: kind, value: value, punctuation: punctuation + tail); text.removeFirst(tail.count) }
                }
                result += text.split(whereSeparator: \.isWhitespace).map { .word(String($0)) }
            }
        }
        return result
    }
    static func accessibilityText(_ runs: [Run]) -> String {
        runs.map {
            switch $0 {
            case .word(let text): return text
            case .chip(let kind, let value, let punctuation):
                let label: String = switch kind { case "time": "Schedule"; case "gh": "GitHub"; case "pc": "Computer"; case "slack": "Slack channel"; default: kind.capitalized }
                return label + " " + value + punctuation
            }
        }.joined(separator: " ")
    }
}
