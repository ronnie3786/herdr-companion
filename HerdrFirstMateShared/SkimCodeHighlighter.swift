import Foundation

/// Language labels and preview line selection for code in skim excerpts.
enum SkimCodeLanguage {
    private static let labels: [String: String] = [
        "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX", "mjs": "JavaScript", "cjs": "JavaScript",
        "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX", "swift": "Swift", "py": "Python",
        "python": "Python", "sh": "Shell", "bash": "Bash", "zsh": "Zsh", "shell": "Shell", "console": "Terminal",
        "terminal": "Terminal", "json": "JSON", "jsonc": "JSON", "diff": "Diff", "patch": "Patch", "go": "Go",
        "rust": "Rust", "rs": "Rust", "java": "Java", "kotlin": "Kotlin", "kt": "Kotlin", "c": "C", "cpp": "C++",
        "rb": "Ruby", "ruby": "Ruby", "php": "PHP", "sql": "SQL", "yaml": "YAML", "yml": "YAML", "toml": "TOML",
        "text": "Text", "txt": "Text", "log": "Log", "output": "Output",
    ]

    static func label(_ language: String?, code: String = "") -> String {
        let key = (language ?? "").lowercased()
        if let label = labels[key] { return label }
        if let first = key.first { return first.uppercased() + key.dropFirst() }
        return isLogLike(code) ? "Output" : "Code"
    }

    static func isLogLike(_ code: String) -> Bool {
        code.components(separatedBy: "\n").contains { SkimCodeHighlighter.passes($0) || SkimCodeHighlighter.fails($0) }
    }

    static func isDiff(_ code: String, language: String?) -> Bool {
        let family = SkimCodeHighlighter.family(for: language)
        return family == .diff || code.range(of: #"(?m)^@@ "#, options: .regularExpression) != nil
    }

    /// The most useful few lines: a diff's changed lines, otherwise the first
    /// lines after leading blanks and imports.
    static func previewLines(_ code: String, language: String?, count: Int = 8) -> (lines: [String], from: Int?, total: Int) {
        let lines = code.components(separatedBy: "\n")
        if isDiff(code, language: language) {
            let changed = lines.filter { $0.range(of: #"^[+-](?![+-]{2})|^@@"#, options: .regularExpression) != nil }
            return (Array(changed.prefix(count)), nil, lines.count)
        }
        let skippable = #"^\s*$|^\s*(?:import\s|from\s+\S+\s+import\s|#include|use\s|package\s|const\s+\w+\s*=\s*require\()"#
        var start = 0
        while start < lines.count - 1, start < 12, lines[start].range(of: skippable, options: .regularExpression) != nil {
            start += 1
        }
        if start == lines.count - 1 { start = 0 }
        return (Array(lines[start..<min(lines.count, start + count)]), start > 0 ? start + 1 : nil, lines.count)
    }
}

/// A small, dependency-free highlighter for verbatim code in excerpts:
/// keywords, strings, comments, numbers, calls, types, and line-level diff and
/// test-output tints. Clients map each style to their own theme colors.
enum SkimCodeHighlighter {
    enum Style: String, Equatable, Sendable {
        case keyword, string, comment, number, function, type, attribute, property, added, removed, hunk
    }

    struct Span: Equatable, Sendable {
        /// UTF-16 range in the highlighted code.
        var location: Int
        var length: Int
        var style: Style
    }

    enum Family: Equatable {
        case js, swift, py, sh, json, generic, diff
    }

    private static let aliases: [String: Family] = [
        "js": .js, "javascript": .js, "jsx": .js, "mjs": .js, "cjs": .js, "ts": .js, "typescript": .js, "tsx": .js,
        "swift": .swift, "py": .py, "python": .py, "sh": .sh, "bash": .sh, "zsh": .sh, "shell": .sh,
        "console": .sh, "terminal": .sh, "json": .json, "jsonc": .json, "diff": .diff, "patch": .diff,
        "go": .generic, "rust": .generic, "rs": .generic, "java": .generic, "kotlin": .generic, "kt": .generic,
        "c": .generic, "cpp": .generic, "c++": .generic, "rb": .generic, "ruby": .generic, "php": .generic,
        "sql": .generic, "yaml": .generic, "yml": .generic, "toml": .generic,
    ]

    static func family(for language: String?) -> Family? { aliases[(language ?? "").lowercased()] }

    private static let cComment = #"//[^\n]*|/\*[\s\S]*?\*/"#
    private static let hashComment = #"(?:^|(?<=\s))#[^\n]*"#
    private static let doubleQuoted = #""(?:\\.|[^"\\\n])*""#
    private static let singleQuoted = #"'(?:\\.|[^'\\\n])*'"#
    private static let backtick = #"`(?:\\[\s\S]|[^`\\])*`"#

    private struct Grammar {
        var comment: String
        var string: String
        var keywords: Set<String>
        var types = false
        var extra: String? = nil
        var commands = false
        var keys = false
    }

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let grammars: [Family: Grammar] = [
        .js: Grammar(comment: cComment, string: "\(backtick)|\(doubleQuoted)|\(singleQuoted)",
                     keywords: words("await async break case catch class const continue default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while yield null undefined true false interface type enum implements readonly as"),
                     types: true),
        .swift: Grammar(comment: cComment, string: #""""[\s\S]*?"""|"# + doubleQuoted,
                        keywords: words("actor any as associatedtype async await break case catch class continue default defer do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while"),
                        types: true, extra: #"[@#][A-Za-z_]\w*"#),
        .py: Grammar(comment: hashComment, string: #""""[\s\S]*?"""|'''[\s\S]*?'''|"# + "\(doubleQuoted)|\(singleQuoted)",
                     keywords: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield self"),
                     types: true, extra: #"@[A-Za-z_][\w.]*"#),
        .sh: Grammar(comment: hashComment, string: "\(doubleQuoted)|\(singleQuoted)",
                     keywords: words("if then else elif fi for in do done while until case esac function return export local cd exit set unset source sudo"),
                     extra: #"\$\{?[A-Za-z_]\w*\}?|(?<=\s)--?[A-Za-z][\w-]*"#, commands: true),
        .json: Grammar(comment: cComment, string: doubleQuoted, keywords: words("true false null"), keys: true),
        .generic: Grammar(comment: "\(cComment)|\(hashComment)", string: "\(doubleQuoted)|\(singleQuoted)",
                          keywords: words("if else for while return func fn def let var const val struct class enum impl trait interface package import use pub public private static void true false nil null none self this new match case switch break continue go defer async await try catch throw"),
                          types: true),
    ]

    static func passes(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:✔|✓|ok\b|PASS\b|passed\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func fails(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:✖|✗|×|not ok\b|FAIL\b|failed\b|Error\b|\w*Error:|AssertionError)"#, options: .regularExpression) != nil
    }

    /// Style spans for `code` written in `language`. Unknown languages get no
    /// token colors, only log tints when the text reads like test output.
    static func spans(_ code: String, language: String?) -> [Span] {
        let family = family(for: language)
        let key = (language ?? "").lowercased()
        if family == .diff || (family == nil && code.range(of: #"(?m)^(?:@@|\+\+\+|---) "#, options: .regularExpression) != nil
                                && code.range(of: #"(?m)^[+-]"#, options: .regularExpression) != nil) {
            return lineSpans(code) { line in
                if line.hasPrefix("@@") { return .hunk }
                if line.hasPrefix("+"), !line.hasPrefix("+++") { return .added }
                if line.hasPrefix("-"), !line.hasPrefix("---") { return .removed }
                return nil
            }
        }
        guard let family, key != "text", key != "log", let grammar = grammars[family] else {
            guard SkimCodeLanguage.isLogLike(code) else { return [] }
            return lineSpans(code) { line in
                fails(line) ? .removed : passes(line) ? .added : line.hasPrefix("ℹ") ? .comment : nil
            }
        }
        return tokenSpans(code, grammar: grammar)
    }

    private static func lineSpans(_ code: String, style: (String) -> Style?) -> [Span] {
        var spans: [Span] = []
        var location = 0
        for line in code.components(separatedBy: "\n") {
            let length = line.utf16.count
            if let chosen = style(line), length > 0 { spans.append(Span(location: location, length: length, style: chosen)) }
            location += length + 1
        }
        return spans
    }

    private static func tokenSpans(_ code: String, grammar: Grammar) -> [Span] {
        let pattern = [
            "(\(grammar.comment))", "(\(grammar.string))", #"(\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#,
            "(\(grammar.extra ?? "(?!)"))", #"([A-Za-z_$][\w$]*)"#,
        ].joined(separator: "|")
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let source = code as NSString
        var spans: [Span] = []
        var last = 0
        var lineStart = true
        for match in expression.matches(in: code, range: NSRange(location: 0, length: source.length)) {
            let before = source.substring(with: NSRange(location: last, length: match.range.location - last))
            if before.contains("\n") {
                lineStart = before.range(of: #"\n\s*(\$\s+)?$"#, options: .regularExpression) != nil
            } else if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                lineStart = false
            }
            let text = source.substring(with: match.range)
            let after = source.substring(from: match.range.location + match.range.length)
            var chosen: Style?
            var keepsLineStart = false
            if match.range(at: 1).location != NSNotFound {
                chosen = .comment
            } else if match.range(at: 2).location != NSNotFound {
                chosen = grammar.keys && after.range(of: #"^\s*:"#, options: .regularExpression) != nil ? .property : .string
            } else if match.range(at: 3).location != NSNotFound {
                chosen = .number
            } else if grammar.extra != nil, match.range(at: 4).location != NSNotFound, match.range(at: 4).length > 0 {
                chosen = .attribute
            } else {
                if grammar.keywords.contains(text) {
                    chosen = .keyword
                } else if grammar.commands, lineStart {
                    chosen = .function
                } else if after.range(of: #"^\s*\("#, options: .regularExpression) != nil {
                    chosen = .function
                } else if grammar.types, text.range(of: #"^[A-Z][a-z0-9]"#, options: .regularExpression) != nil {
                    chosen = .type
                }
                keepsLineStart = grammar.commands && text == "$" && lineStart
            }
            if let chosen { spans.append(Span(location: match.range.location, length: match.range.length, style: chosen)) }
            lineStart = keepsLineStart
            last = match.range.location + match.range.length
        }
        return spans
    }
}
