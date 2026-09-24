import Foundation

/// One contiguous before/after line range inside a saved comment anchor.
///
/// A comment can keep multiple spans when the selected code crosses an
/// added/removed boundary. Each span keeps its own side, so a saved anchor is
/// never rewritten onto a side the reviewer did not select.
struct PRReviewCommentSpan: Codable, Equatable, Sendable {
    var side: PRReviewSide
    var start: Int
    var end: Int

    init(side: PRReviewSide, start: Int, end: Int) {
        self.side = side
        self.start = start
        self.end = end
    }

    /// Coordinates are 1-based and inclusive.
    var isValid: Bool {
        start >= 1 && end >= start
    }
}

/// Why a saved comment anchor cannot be trusted against a loaded diff.
enum PRReviewCommentAnchorProblem: String, Equatable, Sendable {
    case emptyPath
    case emptyCode
    case emptySpans
    case revisionMismatch
    case missingFile
    case binaryFile
    case partialDiff
    case oldPathMismatch
    case invalidSpan
    case lineNotFound
}

/// The immutable location a local comment was composed against.
///
/// The anchor freezes the revision (`baseSHA`/`headSHA`/`mergeBaseSHA`), the
/// current and original paths, the selected sides and line ranges, and the
/// exact selected code. It never moves when the pull request is refreshed: an
/// anchor that no longer matches the loaded diff is reported as stale instead
/// of being rewritten onto whatever currently occupies those lines.
struct PRReviewCommentAnchor: Codable, Equatable, Sendable {
    var baseSHA: String
    var headSHA: String
    var mergeBaseSHA: String?
    /// Post-change path. For a deleted file this is the removed path.
    var path: String
    /// Original path for before-side references; empty when the file was not
    /// renamed.
    var oldPath: String
    var spans: [PRReviewCommentSpan]
    /// Exact selected code. Whitespace and Unicode are preserved unchanged.
    var code: String

    init(
        baseSHA: String,
        headSHA: String,
        mergeBaseSHA: String? = nil,
        path: String,
        oldPath: String = "",
        spans: [PRReviewCommentSpan],
        code: String
    ) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.mergeBaseSHA = mergeBaseSHA
        self.path = path
        self.oldPath = oldPath
        self.spans = spans
        self.code = code
    }

    /// The path before-side source references belong to. Deleted files keep
    /// their single path; renamed files keep the path captured at composition.
    var beforePath: String {
        oldPath.isEmpty ? path : oldPath
    }

    /// Returns the first reason this anchor cannot be trusted in `diff`, or
    /// `nil` when the revision matches and every span exists on its own side of
    /// the matching, complete file diff.
    ///
    /// Anchors are validated here rather than silently moved: a revision
    /// mismatch, a missing or partial file, a binary file, or a span that does
    /// not exist in the loaded hunks all keep the saved anchor untouched.
    func problem(against diff: PRReviewDiff) -> PRReviewCommentAnchorProblem? {
        guard !path.isEmpty else { return .emptyPath }
        guard !code.isEmpty else { return .emptyCode }
        guard !spans.isEmpty else { return .emptySpans }
        guard !baseSHA.isEmpty, !headSHA.isEmpty,
              baseSHA.caseInsensitiveCompare(diff.baseSHA) == .orderedSame,
              headSHA.caseInsensitiveCompare(diff.headSHA) == .orderedSame
        else { return .revisionMismatch }
        guard let file = diff.files.first(where: { $0.path == path }) else { return .missingFile }
        guard !file.binary else { return .binaryFile }
        guard !file.truncated else { return .partialDiff }
        let fileOldPath = (file.oldPath.map { $0.isEmpty ? file.path : $0 }) ?? file.path
        if !oldPath.isEmpty, oldPath != fileOldPath { return .oldPathMismatch }
        for span in spans {
            guard span.isValid else { return .invalidSpan }
            let numbers = Self.lineNumbers(in: file, side: span.side)
            guard numbers.contains(span.start), numbers.contains(span.end) else { return .lineNotFound }
        }
        return nil
    }

    private static func lineNumbers(in file: PRReviewDiffFile, side: PRReviewSide) -> Set<Int> {
        var numbers: Set<Int> = []
        for hunk in file.hunks {
            for line in hunk.lines {
                switch side {
                case .before:
                    if let number = line.oldNumber { numbers.insert(number) }
                case .after:
                    if let number = line.newNumber { numbers.insert(number) }
                }
            }
        }
        return numbers
    }
}

/// The mutable inputs for one new local comment. The store validates and
/// canonicalizes them before anything is recorded.
struct PRReviewCommentDraft: Equatable, Sendable {
    var machineID: String
    var reviewID: String
    var prURL: String
    var anchor: PRReviewCommentAnchor
    var body: String

    init(machineID: String, reviewID: String, prURL: String, anchor: PRReviewCommentAnchor, body: String) {
        self.machineID = machineID
        self.reviewID = reviewID
        self.prURL = prURL
        self.anchor = anchor
        self.body = body
    }
}

/// One locally saved review comment.
///
/// Records are private to this Mac. Herdr never submits the text or marks it
/// published; the only paths out are an explicit copy or an explicit browser
/// navigation the reviewer asks for.
struct PRReviewComment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var machineID: String
    var reviewID: String
    /// Canonical pull request URL without credentials, query, or fragment.
    var prURL: String
    var anchor: PRReviewCommentAnchor
    /// Exact comment text. Blank bodies are rejected; otherwise the text is
    /// stored and returned unchanged, including whitespace and Markdown.
    var body: String
    var createdAt: Date
    var updatedAt: Date
    /// Monotonic optimistic-concurrency value. Every edit must present the
    /// version it loaded, so a second window cannot silently overwrite newer
    /// text.
    var editVersion: Int

    init(
        id: UUID = UUID(),
        machineID: String,
        reviewID: String,
        prURL: String,
        anchor: PRReviewCommentAnchor,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        editVersion: Int = 1
    ) {
        self.id = id
        self.machineID = machineID
        self.reviewID = reviewID
        self.prURL = prURL
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.editVersion = editVersion
    }
}
