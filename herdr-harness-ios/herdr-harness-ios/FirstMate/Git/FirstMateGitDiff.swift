import Foundation

/// One rendered row of a unified diff: a hunk header, or a context, added or
/// removed line with its old and new line numbers. Git's file headers
/// (`diff --git`, `index`, `---`, `+++`, modes) are not rows; notes such as
/// "Binary files differ" or "No newline at end of file" are.
struct FirstMateGitDiffLine: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case hunk, context, added, removed, note }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String

    var marker: String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context, .hunk, .note: " "
        }
    }
}

/// A parsed file diff and its counts.
struct FirstMateGitParsedDiff: Equatable, Sendable {
    let lines: [FirstMateGitDiffLine]
    let additions: Int
    let deletions: Int
    let truncated: Bool

    static let empty = FirstMateGitParsedDiff(lines: [], additions: 0, deletions: 0, truncated: false)

    var isEmpty: Bool { lines.isEmpty }

    init(lines: [FirstMateGitDiffLine], additions: Int, deletions: Int, truncated: Bool) {
        self.lines = lines
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }

    /// Parses `git diff`/`git show` output. Tabs become four spaces so code
    /// columns line up in the monospaced view.
    init(unified diff: String, truncated: Bool = false) {
        var rows: [FirstMateGitDiffLine] = []
        var additions = 0, deletions = 0
        var old = 0, new = 0
        var inHunk = false
        let source = diff.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        func append(_ kind: FirstMateGitDiffLine.Kind, _ old: Int?, _ new: Int?, _ text: String) {
            rows.append(.init(id: rows.count, kind: kind, oldNumber: old, newNumber: new,
                              text: text.replacingOccurrences(of: "\t", with: "    ")))
        }

        for line in lines {
            if line.hasPrefix("@@") {
                if let range = Self.hunkStarts(line) {
                    old = range.old
                    new = range.new
                }
                inHunk = true
                append(.hunk, nil, nil, line)
                continue
            }
            if line.hasPrefix("diff --git ") {
                inHunk = false
                continue
            }
            guard inHunk else {
                // File headers before the first hunk. Keep the human notes.
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    append(.note, nil, nil, line)
                }
                continue
            }
            if line.hasPrefix("\\") {
                append(.note, nil, nil, String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("+") {
                additions += 1
                append(.added, nil, new, String(line.dropFirst()))
                new += 1
            } else if line.hasPrefix("-") {
                deletions += 1
                append(.removed, old, nil, String(line.dropFirst()))
                old += 1
            } else {
                append(.context, old, new, line.isEmpty ? "" : String(line.dropFirst()))
                old += 1
                new += 1
            }
        }
        self.init(lines: rows, additions: additions, deletions: deletions, truncated: truncated)
    }

    /// The old and new start lines of `@@ -41,7 +41,10 @@ …`.
    static func hunkStarts(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3,
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",").first ?? ""),
              let new = Int(parts[2].dropFirst().split(separator: ",").first ?? "")
        else { return nil }
        return (old, new)
    }
}

/// How a Git name-status letter reads in the list.
enum FirstMateGitStatusLetter {
    /// The first letter of a name-status code (`R100` → `R`), or `?`.
    static func letter(_ status: String) -> String {
        guard let first = status.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    static func word(_ status: String) -> String {
        switch letter(status) {
        case "M": "modified"
        case "A": "added"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        case "U": "conflicted"
        case "T": "type changed"
        case "?": "untracked"
        default: "changed"
        }
    }
}

/// A path split into its file name and directory for two-line rows.
struct FirstMateGitPath: Equatable, Sendable {
    let name: String
    let directory: String

    init(_ path: String) {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let slash = trimmed.lastIndex(of: "/") {
            name = String(trimmed[trimmed.index(after: slash)...])
            directory = String(trimmed[..<slash])
        } else {
            name = trimmed
            directory = ""
        }
    }
}
