import Foundation

protocol AgentRolesClient: Sendable {
    func fetchAgentRoles() async throws -> AgentRolesOverview
    func mutateAgentRoles(_ mutation: AgentRoleMutation) async throws -> AgentRolesOverview
    /// Export candidates, without prompts or file contents.
    func fetchAgentRolesSharePreview() async throws -> AgentRolesSharePreview
    /// The roles file exactly as the companion produced it.
    func exportAgentRoles(roleIDs: [String]) async throws -> AgentRolesExport
    /// Sends `document` byte for byte. A dry run returns the plan; a commit applies
    /// the reviewed plan and returns it with the resulting overview. `localSkills`
    /// maps the file's skill IDs found on this Mac to their content hashes, and
    /// must be the same for a dry run and its commit.
    func importAgentRoles(document: Data, dryRun: Bool, expectedRevision: Int?, planDigest: String?,
                          roleIDs: [String]?, replaceRoleIDs: [String]?,
                          localSkills: [String: String]?) async throws -> AgentRolesImportPlan
}

extension AgentRolesClient {
    func fetchAgentRolesSharePreview() async throws -> AgentRolesSharePreview { throw Self.sharingUnsupported }

    func exportAgentRoles(roleIDs: [String]) async throws -> AgentRolesExport { throw Self.sharingUnsupported }

    func importAgentRoles(document: Data, dryRun: Bool, expectedRevision: Int?, planDigest: String?,
                          roleIDs: [String]?, replaceRoleIDs: [String]?,
                          localSkills: [String: String]?) async throws -> AgentRolesImportPlan {
        throw Self.sharingUnsupported
    }

    private static var sharingUnsupported: APIError {
        .server(status: 426, message: "Update the companion to share roles.")
    }
}
