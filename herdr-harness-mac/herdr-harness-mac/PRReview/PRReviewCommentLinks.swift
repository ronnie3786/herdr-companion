import CryptoKit
import Foundation

/// A validated GitHub pull-request location parsed from a saved comment URL.
struct PRReviewPullRequestReference: Equatable, Sendable {
    let host: String
    let owner: String
    let repo: String
    let number: Int
    /// Canonical PR URL: https, no credentials, query, fragment, or default
    /// port, and a lowercase `github.com` family host.
    let canonicalURL: URL
}

/// Pure link helpers for local PR Review comments.
///
/// The helpers never mutate state and never carry the comment text. They build
/// the two links the reviewer uses while publishing manually: the pull
/// request's specific file in the diff, and the original-revision source blob
/// that the saved code excerpt came from. Unsafe schemes, credential-bearing
/// URLs, malformed PR routes, and invalid coordinates are rejected with `nil`
/// instead of producing a link.
enum PRReviewCommentLinks {
    /// GitHub's PR "Files changed" route anchors each file with
    /// `#diff-<sha256 of the file path>`. The hash is computed from the
    /// canonical path saved in the anchor, so a renamed file uses its current
    /// path and a deleted file keeps the path it was removed from.
    static func diffAnchorHash(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses and canonicalizes a stored pull request URL.
    static func reference(from value: String) -> PRReviewPullRequestReference? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNewline),
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let rawHost = components.host,
              let host = canonicalHost(rawHost)
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4,
              parts[2] == "pull",
              let number = Int(parts[3]),
              number > 0,
              isValidSlug(parts[0]),
              isValidSlug(parts[1])
        else { return nil }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host
        canonical.path = "/\(parts[0])/\(parts[1])/pull/\(number)"
        guard let canonicalURL = canonical.url else { return nil }
        return PRReviewPullRequestReference(
            host: host,
            owner: parts[0],
            repo: parts[1],
            number: number,
            canonicalURL: canonicalURL
        )
    }

    /// The canonical stored form of a pull request URL.
    static func canonicalPRURL(from value: String) -> URL? {
        reference(from: value)?.canonicalURL
    }

    /// The PR diff route for one file, using the current path from the anchor.
    static func filesURL(prURL: String, currentPath: String) -> URL? {
        guard encodedPath(currentPath) != nil, let reference = reference(from: prURL) else { return nil }
        let hash = diffAnchorHash(for: currentPath)
        return makeURL(
            reference: reference,
            percentEncodedPath: "/\(reference.owner)/\(reference.repo)/pull/\(reference.number)/files",
            fragment: "diff-\(hash)"
        )
    }

    /// The PR diff route for a saved comment's file.
    static func filesURL(for comment: PRReviewComment) -> URL? {
        filesURL(prURL: comment.prURL, currentPath: comment.anchor.path)
    }

    /// The commit the original-revision blob links should read: the merge base
    /// when the saved review captured one, otherwise the PR base SHA.
    static func originalRevisionSHA(for anchor: PRReviewCommentAnchor) -> String? {
        let mergeBase = anchor.mergeBaseSHA?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isCommitSHA(mergeBase) { return mergeBase }
        let base = anchor.baseSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        return isCommitSHA(base) ? base : nil
    }

    /// A blob link to the original revision of the saved code.
    ///
    /// Before-side spans read the original path (retained for renamed files);
    /// after-side spans read the current path. The optional span adds the
    /// inclusive `#L…` fragment for the exact saved range.
    static func originalRevisionBlobURL(
        prURL: String,
        anchor: PRReviewCommentAnchor,
        side: PRReviewSide,
        span: PRReviewCommentSpan? = nil
    ) -> URL? {
        guard let reference = reference(from: prURL),
              let sha = originalRevisionSHA(for: anchor)
        else { return nil }
        let path = side == .before ? anchor.beforePath : anchor.path
        guard let encodedPath = encodedPath(path) else { return nil }
        var fragment: String?
        if let span {
            guard span.side == side, span.isValid else { return nil }
            fragment = span.start == span.end ? "L\(span.start)" : "L\(span.start)-L\(span.end)"
        }
        return makeURL(
            reference: reference,
            percentEncodedPath: "/\(reference.owner)/\(reference.repo)/blob/\(sha)/\(encodedPath)",
            fragment: fragment
        )
    }

    /// A blob link for a saved comment, using its own retained paths.
    static func originalRevisionBlobURL(
        for comment: PRReviewComment,
        side: PRReviewSide,
        span: PRReviewCommentSpan? = nil
    ) -> URL? {
        originalRevisionBlobURL(prURL: comment.prURL, anchor: comment.anchor, side: side, span: span)
    }

    // MARK: - Parsing

    private static func canonicalHost(_ host: String) -> String? {
        let lowered = host.lowercased()
        guard lowered == "github.com" || lowered.hasSuffix(".github.com") else { return nil }
        return lowered == "www.github.com" ? "github.com" : lowered
    }

    private static func isValidSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
        }
    }

    private static func isCommitSHA(_ value: String) -> Bool {
        guard (7...64).contains(value.count) else { return false }
        return value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    // MARK: - Building

    /// Percent-encodes each path component independently so separators stay
    /// separators while spaces, `#`, `%`, and Unicode are escaped exactly once.
    private static func encodedPath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        var encoded: [String] = []
        encoded.reserveCapacity(segments.count)
        for segment in segments {
            guard let value = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            encoded.append(value)
        }
        return encoded.joined(separator: "/")
    }

    private static func makeURL(
        reference: PRReviewPullRequestReference,
        percentEncodedPath: String,
        fragment: String?
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = reference.host
        components.percentEncodedPath = percentEncodedPath
        if let fragment {
            components.percentEncodedFragment = fragment
        }
        return components.url
    }
}
