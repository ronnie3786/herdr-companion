import Foundation

/// One private, feature-scoped link retained by the companion.
///
/// The value is presentation data only. Recognizing a GitHub pull request says
/// nothing about draft, ready, merged, or closed state, and the client never
/// fetches, previews, or publishes a destination.
struct FirstMateLink: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var featureID: String
    var url: String
    var kind: String
    var title: String
    var titleSource: String
    var source: String
    var provenance: FirstMateLinkProvenance
    var hidden: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, url, kind, title, source, provenance, hidden
        case featureID = "feature_id"
        case titleSource = "title_source"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    init(
        id: String,
        featureID: String,
        url: String,
        kind: String,
        title: String,
        titleSource: String = "",
        source: String,
        provenance: FirstMateLinkProvenance = .init(),
        hidden: Bool = false,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.featureID = featureID
        self.url = url
        self.kind = kind
        self.title = title
        self.titleSource = titleSource
        self.source = source
        self.provenance = provenance
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        featureID = try container.decode(String.self, forKey: .featureID)
        url = try container.decode(String.self, forKey: .url)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleSource = try container.decodeIfPresent(String.self, forKey: .titleSource) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "user"
        provenance = try container.decodeIfPresent(FirstMateLinkProvenance.self, forKey: .provenance) ?? .init()
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var isPullRequest: Bool { kind == "pull_request" }
    var isHidden: Bool { hidden }

    /// The inspectable host, including a non-default port when one was saved.
    var hostLabel: String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }

    /// A validated destination. Opening and copying always go through this.
    var destination: URL? { FirstMateLinkURL.validated(url) }

    /// Provenance shown beside the link when it was not an explicit user save.
    var provenanceSummary: String? {
        switch source {
        case "discovery": "Detected from saved evidence"
        case "agent": "Saved by a managed agent"
        default: nil
        }
    }
}

/// Bounded, server-derived evidence for an automatically retained link.
struct FirstMateLinkProvenance: Codable, Equatable, Sendable {
    var nativeSessionID: String?
    var assignmentID: String?
    var documentID: String?
    var messageID: String?
    var observedAt: String?

    enum CodingKeys: String, CodingKey {
        case nativeSessionID = "native_session_id"
        case assignmentID = "assignment_id"
        case documentID = "document_id"
        case messageID = "message_id"
        case observedAt = "observed_at"
    }

    init(
        nativeSessionID: String? = nil,
        assignmentID: String? = nil,
        documentID: String? = nil,
        messageID: String? = nil,
        observedAt: String? = nil
    ) {
        self.nativeSessionID = nativeSessionID
        self.assignmentID = assignmentID
        self.documentID = documentID
        self.messageID = messageID
        self.observedAt = observedAt
    }
}

/// What the Add form and the store send for an explicit save.
struct FirstMateLinkDraft: Equatable, Sendable {
    var url: String
    var title: String
    /// `nil` lets the companion classify the URL; otherwise `pull_request` or `link`.
    var kind: String?

    init(url: String = "", title: String = "", kind: String? = nil) {
        self.url = url
        self.title = title
        self.kind = kind
    }

    var isEmpty: Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The optional classification the Add form offers.
enum FirstMateLinkClassification: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case pullRequest = "pull_request"
    case link

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .pullRequest: "Pull request"
        case .link: "Link"
        }
    }
    var kind: String? { self == .automatic ? nil : rawValue }
}

/// Deterministic link ordering. The companion's creation order is retained and
/// no mention order, label, or branch name is promoted to a primary PR.
enum FirstMateLinkOrdering {
    static func sorted(_ links: [FirstMateLink]) -> [FirstMateLink] {
        links.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
    }

    static func visiblePullRequests(_ links: [FirstMateLink]) -> [FirstMateLink] {
        sorted(links.filter { !$0.hidden && $0.isPullRequest })
    }

    static func visibleOtherLinks(_ links: [FirstMateLink]) -> [FirstMateLink] {
        sorted(links.filter { !$0.hidden && !$0.isPullRequest })
    }

    static func hidden(_ links: [FirstMateLink]) -> [FirstMateLink] {
        sorted(links.filter(\.hidden))
    }
}

/// Exact GitHub pull request recognition, mirroring the companion convention.
struct FirstMatePullRequestIdentity: Equatable, Sendable {
    var owner: String
    var repo: String
    var number: Int
    var url: String
}

/// One normalized link value. Used locally to validate before a request and to
/// drive the synthetic demo, which has no server to classify or canonicalize.
struct FirstMateNormalizedLink: Equatable, Sendable {
    var url: String
    var kind: String
    var title: String
    var titleSupplied: Bool
    var pullRequest: FirstMatePullRequestIdentity?
}

enum FirstMateLinkClassifier {
    static let maximumTitleLength = 300

    /// Returns `nil` for anything the companion would reject.
    static func normalize(url: String, title: String = "", kind: String? = nil) -> FirstMateNormalizedLink? {
        guard let parsed = FirstMateLinkURL.validated(url) else { return nil }
        let pullRequest = githubPullRequest(parsed)
        let normalizedKind: String
        if let kind, !kind.isEmpty {
            guard kind == "pull_request" || kind == "link" else { return nil }
            normalizedKind = kind
        } else {
            normalizedKind = pullRequest == nil ? "link" : "pull_request"
        }
        let suppliedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suppliedTitle.count <= maximumTitleLength else { return nil }
        let canonicalURL = pullRequest.map { $0.url } ?? canonicalGeneralURL(parsed)
        return FirstMateNormalizedLink(
            url: canonicalURL,
            kind: normalizedKind,
            title: suppliedTitle.isEmpty ? defaultTitle(canonicalURL: canonicalURL, kind: normalizedKind) : suppliedTitle,
            titleSupplied: !suppliedTitle.isEmpty,
            pullRequest: pullRequest
        )
    }

    static func githubPullRequest(_ url: URL) -> FirstMatePullRequestIdentity? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let path = url.path
        let pattern = "^/([^/]+)/([^/]+)/pull/([0-9]+)(?:/.*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let ownerRange = Range(match.range(at: 1), in: path),
              let repoRange = Range(match.range(at: 2), in: path),
              let numberRange = Range(match.range(at: 3), in: path),
              let number = Int(path[numberRange]) else { return nil }
        let owner = String(path[ownerRange])
        let repo = String(path[repoRange])
        return FirstMatePullRequestIdentity(
            owner: owner,
            repo: repo,
            number: number,
            url: "https://github.com/\(owner)/\(repo)/pull/\(number)"
        )
    }

    static func defaultTitle(canonicalURL: String, kind: String) -> String {
        if kind == "pull_request", let identity = URL(string: canonicalURL).flatMap(githubPullRequest) {
            return "\(identity.owner)/\(identity.repo) #\(identity.number)"
        }
        return URLComponents(string: canonicalURL)?.host ?? canonicalURL
    }

    private static func canonicalGeneralURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString ?? url.absoluteString
    }
}

/// Bounded absolute HTTP(S) validation shared by saving, opening, and copying.
enum FirstMateLinkURL {
    static let maximumLength = 4096

    /// Returns the parsed URL only for a bounded, absolute, credential-free
    /// HTTP(S) address whose host and port are well formed.
    static func validated(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host,
              isValidHost(host) else { return nil }
        if let port = url.port, !(1...65535).contains(port) { return nil }
        guard url.absoluteString.count <= maximumLength else { return nil }
        return url
    }

    static func isOpenable(_ url: URL) -> Bool {
        validated(url.absoluteString) != nil
    }

    /// Host labels use letters, digits, and inner hyphens, matching the
    /// companion's existing convention. IPv6 literals are not accepted there.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let label = "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
        let pattern = "^\(label)(?:\\.\(label))*$"
        return host.range(of: pattern, options: .regularExpression) != nil
    }
}
