import Foundation

/// First Mate Git (capability `first-mate-git-v1`). Feature-scoped: the
/// companion resolves the checkout from the feature's own records, so the
/// app sends a workspace ID (`project` or an assignment), never a path.
/// Reads and mutations carry `expected_root` from the status snapshot.
extension HerdrAPIClient {
    /// Git runs for up to ten seconds on the companion; leave headroom for the
    /// authenticated proxy hop. (The generic First Mate rule would give these
    /// POSTs a day-long timeout meant for agent turns.)
    static let firstMateGitTimeout: TimeInterval = 30

    func fetchFirstMateGitCheckouts(featureID: String) async throws -> FirstMateGitCheckoutCatalog {
        try await firstMateGitGET(try firstMateGitPath(featureID, "workspaces"))
    }

    func fetchFirstMateGitStatus(featureID: String, workspaceID: String) async throws -> FirstMateGitStatus {
        try await firstMateGitGET(try firstMateGitPath(featureID), query: [
            URLQueryItem(name: "workspace", value: workspaceID),
        ])
    }

    func fetchFirstMateGitDiff(
        featureID: String, workspaceID: String, file: String, section: GitFileSection, expectedRoot: String
    ) async throws -> FirstMateGitDiffResponse {
        try await firstMateGitGET(try firstMateGitPath(featureID, "diff"), query: [
            URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "section", value: section.rawValue),
            URLQueryItem(name: "expected_root", value: expectedRoot),
        ])
    }

    func fetchFirstMateGitCommitFiles(
        featureID: String, workspaceID: String, hash: String, expectedRoot: String
    ) async throws -> FirstMateGitCommitFilesResponse {
        try await firstMateGitGET(try firstMateGitPath(featureID, "commit-files"), query: [
            URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "expected_root", value: expectedRoot),
        ])
    }

    func fetchFirstMateGitCommitDiff(
        featureID: String, workspaceID: String, hash: String, file: String, expectedRoot: String
    ) async throws -> FirstMateGitDiffResponse {
        try await firstMateGitGET(try firstMateGitPath(featureID, "commit-diff"), query: [
            URLQueryItem(name: "workspace", value: workspaceID),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "expected_root", value: expectedRoot),
        ])
    }

    func stageFirstMateGitFile(featureID: String, workspaceID: String, file: String, expectedRoot: String) async throws {
        try await firstMateGitMutation("stage", featureID: featureID,
                                       body: .init(workspace: workspaceID, file: file, expectedRoot: expectedRoot))
    }

    func unstageFirstMateGitFile(featureID: String, workspaceID: String, file: String, expectedRoot: String) async throws {
        try await firstMateGitMutation("unstage", featureID: featureID,
                                       body: .init(workspace: workspaceID, file: file, expectedRoot: expectedRoot))
    }

    /// `/api/v1/first-mate/features/{id}/git[/action]`.
    func firstMateGitPath(_ featureID: String, _ action: String? = nil) throws -> String {
        let base = try firstMatePath("features", id: featureID) + "/git"
        return action.map { base + "/" + $0 } ?? base
    }

    private func firstMateGitMutation(_ action: String, featureID: String, body: FirstMateGitFileRequest) async throws {
        var request = makeRequest(path: try firstMateGitPath(featureID, action), method: "POST")
        request.timeoutInterval = Self.firstMateGitTimeout
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response: FirstMateGitMutationResponse = try await firstMateGitSend(request)
        guard response.ok else { throw APIError.invalidResponse }
    }

    private func firstMateGitGET<Response: Decodable & Sendable>(
        _ path: String, query: [URLQueryItem] = []
    ) async throws -> Response {
        var request = makeRequest(path: path, method: "GET", query: query)
        request.timeoutInterval = Self.firstMateGitTimeout
        request.url = request.url.map(Self.firstMateGitEncodingPlus)
        return try await firstMateGitSend(request)
    }

    /// URLComponents leaves `+` literal in queries, and the companion's form
    /// decoding reads it as a space. File paths such as `A+B.swift` must keep it.
    static func firstMateGitEncodingPlus(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, query.contains("+") else { return url }
        components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }

    private func firstMateGitSend<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }
}
