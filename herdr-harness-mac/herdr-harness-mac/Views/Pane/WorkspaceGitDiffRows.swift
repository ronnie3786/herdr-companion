import SwiftUI

/// One drawn row of the native unified diff (`WorkspaceGitView`).
///
/// The patch is parsed once per loaded diff, off the main actor, so scrolling
/// and hovering never re-split or re-highlight the text.
struct WorkspaceGitDiffRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Pre-hunk lines worth reading (binary notices, mode changes, the
        /// empty-diff placeholder). `diff`/`index`/`---`/`+++` are dropped.
        case note
        /// `@@ -a,b +c,d @@ context`.
        case hunk
        /// Unchanged lines Git left out between two hunks.
        case fold(Int)
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`.
        case marker
    }

    let id: Int
    let kind: Kind
    /// New-side number for context and additions, old-side for deletions.
    let number: Int?
    let text: String
    /// Syntax-highlighted `text`; runs without a color use the row's ink.
    let highlighted: AttributedString?

    var accessibilityLabel: String {
        let line = number.map { " \($0)" } ?? ""
        switch kind {
        case .addition: return "Added line\(line): \(text)"
        case .deletion: return "Removed line\(line): \(text)"
        case .context: return "Line\(line): \(text)"
        case let .fold(count): return "\(count) unmodified \(count == 1 ? "line" : "lines")"
        case .hunk, .note, .marker: return text
        }
    }
}

struct WorkspaceGitParsedDiff: Equatable, Sendable {
    var rows: [WorkspaceGitDiffRow] = []
    var additions = 0
    var deletions = 0
    /// The longest code row in characters (tabs expanded), for sizing the
    /// horizontally scrolling content so every row background spans it.
    var longestLine = 0
}

enum WorkspaceGitDiffParser {
    /// Past this many rows the diff stays plain text: highlighting is a
    /// reading aid, not worth a long parse.
    static let highlightRowLimit = 4_000
    static let highlightColumnLimit = 400

    static func parse(_ diff: String, file: String) -> WorkspaceGitParsedDiff {
        let language = WorkspaceGitSyntax.Language(file: file)
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let highlight = language != nil && lines.count <= highlightRowLimit
        var parsed = WorkspaceGitParsedDiff()
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var previousHunkOldEnd: Int?

        func append(_ kind: WorkspaceGitDiffRow.Kind, number: Int? = nil, text: String, code: Bool = false) {
            let display = code ? text.replacingOccurrences(of: "\t", with: "    ") : text
            if code { parsed.longestLine = max(parsed.longestLine, display.count) }
            let highlighted: AttributedString? = code && highlight && display.utf8.count <= highlightColumnLimit
                ? language.map { WorkspaceGitSyntax.highlight(display, language: $0) }
                : nil
            parsed.rows.append(WorkspaceGitDiffRow(
                id: parsed.rows.count,
                kind: kind,
                number: number,
                text: display,
                highlighted: highlighted
            ))
        }

        for (index, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            // A trailing newline yields one empty final element; it is not a row.
            if line.isEmpty, index == lines.count - 1 { continue }

            if line.hasPrefix("@@"), let header = HunkHeader(line) {
                if let previousHunkOldEnd, header.oldStart > previousHunkOldEnd {
                    append(.fold(header.oldStart - previousHunkOldEnd), text: "")
                }
                previousHunkOldEnd = header.oldStart + header.oldCount
                oldLine = header.oldStart
                newLine = header.newStart
                inHunk = true
                append(.hunk, text: line)
                continue
            }

            if inHunk, let marker = line.first {
                let body = String(line.dropFirst())
                switch marker {
                case "+":
                    parsed.additions += 1
                    append(.addition, number: newLine, text: body, code: true)
                    newLine += 1
                    continue
                case "-":
                    parsed.deletions += 1
                    append(.deletion, number: oldLine, text: body, code: true)
                    oldLine += 1
                    continue
                case " ":
                    append(.context, number: newLine, text: body, code: true)
                    oldLine += 1
                    newLine += 1
                    continue
                case "\\":
                    append(.marker, text: line)
                    continue
                default:
                    // A new file section of a multi-file patch.
                    inHunk = false
                    previousHunkOldEnd = nil
                }
            }

            if isHiddenMetadata(line) { continue }
            append(.note, text: line)
        }
        return parsed
    }

    private static func isHiddenMetadata(_ line: String) -> Bool {
        line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
    }

    /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@`.
    struct HunkHeader: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int

        init?(_ line: String) {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0] == "@@",
                  parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
                  let old = Self.range(parts[1].dropFirst()),
                  let new = Self.range(parts[2].dropFirst())
            else { return nil }
            oldStart = old.start
            oldCount = old.count
            newStart = new.start
            newCount = new.count
        }

        private static func range(_ value: Substring) -> (start: Int, count: Int)? {
            let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(pieces[0]) else { return nil }
            guard pieces.count > 1 else { return (start, 1) }
            guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
            return (start, count)
        }
    }
}

/// A small, capped highlighter for diff rows using MonoCode's dark syntax
/// palette (`HerdrTheme.Syntax`). It colors keywords, types, calls, strings,
/// comments and literals on one line at a time; it is a reading aid, not a
/// grammar, so block comments and multi-line strings stay plain.
enum WorkspaceGitSyntax {
    enum Language: Sendable {
        case cFamily
        case hash

        init?(file: String) {
            let name = file.split(separator: "/").last.map(String.init) ?? file
            guard let dot = name.lastIndex(of: ".") else { return nil }
            switch name[name.index(after: dot)...].lowercased() {
            case "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "rs", "kt", "kts",
                 "java", "c", "h", "m", "mm", "cc", "cpp", "hpp", "cs", "scala", "dart",
                 "css", "scss", "json", "jsonc":
                self = .cFamily
            case "py", "rb", "sh", "bash", "zsh", "toml", "yml", "yaml":
                self = .hash
            default:
                return nil
            }
        }

        var lineComment: String {
            switch self {
            case .cFamily: "//"
            case .hash: "#"
            }
        }
    }

    private static let keywords: Set<String> = [
        "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "def", "default", "defer", "do", "elif", "else", "enum", "export", "extends",
        "extension", "fileprivate", "final", "fn", "for", "from", "func", "function", "guard", "if",
        "impl", "import", "in", "init", "inout", "interface", "internal", "is", "let", "match", "mut",
        "new", "open", "override", "package", "private", "protocol", "pub", "public", "repeat",
        "return", "self", "Self", "some", "any", "static", "struct", "super", "switch", "this", "throw",
        "throws", "trait", "try", "type", "typealias", "use", "var", "where", "while", "with", "yield",
        "lambda", "not", "and", "or", "pass", "raise", "except", "finally", "then", "fi", "done", "esac",
    ]

    private static let constants: Set<String> = [
        "true", "false", "nil", "null", "undefined", "None", "True", "False",
    ]

    static func highlight(_ line: String, language: Language) -> AttributedString {
        let scalars = Array(line.unicodeScalars)
        var result = AttributedString()
        var plainStart = 0
        var index = 0

        func flushPlain(upTo end: Int) {
            guard end > plainStart else { return }
            result += AttributedString(text(scalars[plainStart..<end]))
        }

        func emit(_ start: Int, _ end: Int, _ color: Color) {
            flushPlain(upTo: start)
            var run = AttributedString(text(scalars[start..<end]))
            run.foregroundColor = color
            result += run
            plainStart = end
        }

        let comment = Array(language.lineComment.unicodeScalars)
        while index < scalars.count {
            let scalar = scalars[index]
            if scalars[index...].starts(with: comment) {
                emit(index, scalars.count, HerdrTheme.Syntax.comment)
                index = scalars.count
                break
            }
            if scalar == "\"" || scalar == "'" || scalar == "`" {
                var end = index + 1
                while end < scalars.count, scalars[end] != scalar {
                    end += scalars[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, scalars.count)
                emit(index, end, HerdrTheme.Syntax.string)
                index = end
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar),
               index == 0 || !isIdentifier(scalars[index - 1]) {
                var end = index + 1
                while end < scalars.count, isIdentifier(scalars[end]) || scalars[end] == "." {
                    end += 1
                }
                emit(index, end, HerdrTheme.Syntax.property)
                index = end
                continue
            }
            if isIdentifierStart(scalar) || scalar == "@" {
                var end = index + 1
                while end < scalars.count, isIdentifier(scalars[end]) { end += 1 }
                let word = text(scalars[index..<end])
                if scalar == "@" || keywords.contains(word) {
                    emit(index, end, HerdrTheme.Syntax.keyword)
                } else if constants.contains(word) {
                    emit(index, end, HerdrTheme.Syntax.property)
                } else if CharacterSet.uppercaseLetters.contains(scalar) {
                    emit(index, end, HerdrTheme.Syntax.type)
                } else if nextNonSpace(scalars, from: end) == "(" {
                    emit(index, end, HerdrTheme.Syntax.callable)
                }
                index = end
                continue
            }
            index += 1
        }
        flushPlain(upTo: scalars.count)
        return result
    }

    private static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || CharacterSet.letters.contains(scalar)
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }

    private static func nextNonSpace(_ scalars: [Unicode.Scalar], from index: Int) -> Unicode.Scalar? {
        var index = index
        while index < scalars.count, scalars[index] == " " { index += 1 }
        return index < scalars.count ? scalars[index] : nil
    }
}
