import Foundation

struct FirstMateGitWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let path: String
    var aliases: [String]? = nil
    var branch: String? = nil

    func matches(_ workspaceID: String) -> Bool {
        id == workspaceID || (aliases?.contains(workspaceID) ?? false)
    }
}

struct FirstMateGitWorkspaceResponse: Decodable, Sendable {
    let ok: Bool
    let workspaces: [FirstMateGitWorkspace]
    var defaultWorkspaceID: String? = nil
    var selectionMessage: String? = nil

    enum CodingKeys: String, CodingKey {
        case ok, workspaces
        case defaultWorkspaceID = "default_workspace_id"
        case selectionMessage = "selection_message"
    }
}

protocol FirstMateGitClient: Sendable {
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities
    func fetchFirstMateGitWorkspaces(featureID: String) async throws -> FirstMateGitWorkspaceResponse
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot
}

extension HerdrAPIClient: FirstMateGitClient {}

enum FirstMateGitDemo {
    static let workspaces = [
        FirstMateGitWorkspace(
            id: "project",
            title: "Project workspace",
            path: "/demo/herdr-companion"
        ),
        FirstMateGitWorkspace(
            id: "demo-worker",
            title: "Implementation worker",
            path: "/demo/worktrees/implementation"
        ),
    ]

    static func nativeWorkspace(for workspace: FirstMateGitWorkspace) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: "first-mate-git-\(workspace.id)",
            number: 0,
            label: workspace.title,
            focused: true,
            paneCount: 0,
            tabCount: 0,
            activeTabID: "",
            agentStatus: .unknown,
            tokens: ["branch": workspace.id == "project" ? "main" : "feature/demo-worker"],
            worktree: HerdrWorktree(
                repoKey: "first-mate-demo",
                repoName: "herdr-companion",
                repoRoot: FirstMateGitDemo.workspaces[0].path,
                checkoutPath: workspace.path,
                isLinkedWorktree: workspace.id != "project"
            )
        )
        .stamped(machineID: "demo")
    }
}
