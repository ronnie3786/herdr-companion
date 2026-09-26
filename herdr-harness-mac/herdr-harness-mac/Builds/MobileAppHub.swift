import Foundation

/// Read-only access to a Mobile App Hub: a private, tailnet-only web app that
/// keeps installable iOS builds. Agents publish builds there and tag each one
/// with the First Mate session that produced it; Herdr only reads.
enum MobileAppHubSettings {
    static let hubURLKey = "herdr.builds.hubURL"
    static let dashboardBundleIDsKey = "herdr.builds.dashboardBundleIDs"

    /// An http(s) address with a host, without a trailing slash. Anything else
    /// leaves the Builds sections hidden.
    static func hubURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        var normalized = components
        while normalized.path.hasSuffix("/") { normalized.path.removeLast() }
        return normalized.url
    }

    /// Bundle identifiers separated by commas, spaces, or new lines.
    static func bundleIDs(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }
}

struct MobileAppHubBuild: Decodable, Identifiable, Equatable, Sendable {
    struct App: Decodable, Equatable, Sendable {
        let name: String
        let bundleID: String
        let slug: String

        enum CodingKeys: String, CodingKey {
            case name, slug
            case bundleID = "bundle_id"
        }
    }

    struct Label: Decodable, Equatable, Sendable {
        let ticket: String?
        let title: String?
    }

    struct Source: Decodable, Equatable, Sendable {
        let machine: String?
        let branch: String?
    }

    struct URLs: Decodable, Equatable, Sendable {
        let page: URL
        let appPage: URL?
        let icon: URL?

        enum CodingKeys: String, CodingKey {
            case page, icon
            case appPage = "app_page"
        }
    }

    struct Signing: Decodable, Equatable, Sendable {
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    /// The Herdr session that published (or re-published) the build.
    struct HerdrContext: Decodable, Equatable, Sendable {
        let firstMateFeatureID: String?
        let firstMateAssignmentID: String?

        enum CodingKeys: String, CodingKey {
            case firstMateFeatureID = "first_mate_feature_id"
            case firstMateAssignmentID = "first_mate_assignment_id"
        }
    }

    let id: String
    let app: App
    let version: String
    let buildNumber: String
    let builtAt: Date?
    let uploadedAt: Date
    let label: Label
    let source: Source
    let urls: URLs
    let signing: Signing?
    let herdrContexts: [HerdrContext]

    enum CodingKeys: String, CodingKey {
        case id, app, version, label, source, urls, signing
        case buildNumber = "build_number"
        case builtAt = "built_at"
        case uploadedAt = "uploaded_at"
        case herdrContexts = "herdr_contexts"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        app = try container.decode(App.self, forKey: .app)
        version = try container.decode(String.self, forKey: .version)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        builtAt = try container.decodeIfPresent(Date.self, forKey: .builtAt)
        uploadedAt = try container.decode(Date.self, forKey: .uploadedAt)
        label = try container.decode(Label.self, forKey: .label)
        source = try container.decode(Source.self, forKey: .source)
        urls = try container.decode(URLs.self, forKey: .urls)
        signing = try container.decodeIfPresent(Signing.self, forKey: .signing)
        herdrContexts = try container.decodeIfPresent([HerdrContext].self, forKey: .herdrContexts) ?? []
    }

    /// When the build was made; older hub records only know the upload time.
    var date: Date { builtAt ?? uploadedAt }

    var title: String {
        if let title = label.title, !title.isEmpty { return title }
        if let branch = source.branch, !branch.isEmpty { return branch }
        return "Build \(buildNumber)"
    }

    var versionLabel: String { "\(version) (\(buildNumber))" }

    func isSigningExpired(now: Date = .now) -> Bool {
        guard let expiresAt = signing?.expiresAt else { return false }
        return expiresAt < now
    }

    /// The assignments of `featureID` that produced this build.
    func assignmentIDs(featureID: String) -> [String] {
        herdrContexts.filter { $0.firstMateFeatureID == featureID }.compactMap(\.firstMateAssignmentID)
    }
}

enum MobileAppHubError: LocalizedError, Equatable {
    case unreachable(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case let .unreachable(detail): "Mobile App Hub is unreachable (\(detail)). Check that Tailscale is connected."
        case let .server(status): "Mobile App Hub returned an error (\(status))."
        }
    }
}

struct MobileAppHubClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        let settings = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 15
        settings.waitsForConnectivity = false
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: settings)
    }

    /// Newest first. Filters combine: builds of any listed app, and (when given)
    /// only builds tagged with that First Mate.
    func builds(bundleIDs: [String] = [], firstMateFeatureID: String? = nil, limit: Int = 20) async throws -> [MobileAppHubBuild] {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/builds"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 500))))]
        if !bundleIDs.isEmpty { query.append(URLQueryItem(name: "bundle_id", value: bundleIDs.joined(separator: ","))) }
        if let firstMateFeatureID { query.append(URLQueryItem(name: "first_mate_feature", value: firstMateFeatureID)) }
        components?.queryItems = query
        guard let url = components?.url else { throw MobileAppHubError.unreachable("invalid address") }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MobileAppHubError.unreachable((error as? URLError)?.localizedDescription ?? "network error")
        }
        guard let http = response as? HTTPURLResponse else { throw MobileAppHubError.unreachable("no response") }
        guard (200 ..< 300).contains(http.statusCode) else { throw MobileAppHubError.server(http.statusCode) }
        return try Self.decoder.decode(BuildsEnvelope.self, from: data).builds
    }

    private struct BuildsEnvelope: Decodable {
        let builds: [MobileAppHubBuild]
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
