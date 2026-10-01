import Foundation

/// Where First Mate Git reads and changes one feature's checkouts: the
/// owning machine's companion, or the synthetic demo.
protocol FirstMateGitBackend: Sendable {
    /// False when the companion predates First Mate Git.
    func supportsGit() async throws -> Bool
    func checkouts() async throws -> FirstMateGitCheckoutCatalog
    func status(workspace: String) async throws -> FirstMateGitStatus
    func diff(workspace: String, file: String, section: GitFileSection, expectedRoot: String) async throws -> FirstMateGitDiffResponse
    func stage(workspace: String, file: String, expectedRoot: String) async throws
    func unstage(workspace: String, file: String, expectedRoot: String) async throws
    func commitFiles(workspace: String, hash: String, expectedRoot: String) async throws -> FirstMateGitCommitFilesResponse
    func commitDiff(workspace: String, hash: String, file: String, expectedRoot: String) async throws -> FirstMateGitDiffResponse
}

/// The feature's owning companion.
struct FirstMateGitLiveBackend: FirstMateGitBackend {
    static let capability = "first-mate-git-v1"

    let client: HerdrAPIClient
    let featureID: String

    func supportsGit() async throws -> Bool {
        do {
            let capabilities = try await client.fetchFirstMateCapabilities()
            return capabilities.ok && capabilities.capabilities.contains(Self.capability)
        } catch APIError.server(let status, _) where status == 404 {
            return false
        }
    }

    func checkouts() async throws -> FirstMateGitCheckoutCatalog {
        let catalog = try await client.fetchFirstMateGitCheckouts(featureID: featureID)
        guard catalog.ok else { throw APIError.invalidResponse }
        return catalog
    }

    func status(workspace: String) async throws -> FirstMateGitStatus {
        let status = try await client.fetchFirstMateGitStatus(featureID: featureID, workspaceID: workspace)
        guard status.ok else { throw APIError.invalidResponse }
        return status
    }

    func diff(workspace: String, file: String, section: GitFileSection, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        try await client.fetchFirstMateGitDiff(featureID: featureID, workspaceID: workspace, file: file,
                                               section: section, expectedRoot: expectedRoot)
    }

    func stage(workspace: String, file: String, expectedRoot: String) async throws {
        try await client.stageFirstMateGitFile(featureID: featureID, workspaceID: workspace, file: file, expectedRoot: expectedRoot)
    }

    func unstage(workspace: String, file: String, expectedRoot: String) async throws {
        try await client.unstageFirstMateGitFile(featureID: featureID, workspaceID: workspace, file: file, expectedRoot: expectedRoot)
    }

    func commitFiles(workspace: String, hash: String, expectedRoot: String) async throws -> FirstMateGitCommitFilesResponse {
        try await client.fetchFirstMateGitCommitFiles(featureID: featureID, workspaceID: workspace, hash: hash, expectedRoot: expectedRoot)
    }

    func commitDiff(workspace: String, hash: String, file: String, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        try await client.fetchFirstMateGitCommitDiff(featureID: featureID, workspaceID: workspace, hash: hash,
                                                     file: file, expectedRoot: expectedRoot)
    }
}
