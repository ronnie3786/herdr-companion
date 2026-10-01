import Foundation

// Responses of the companion's First Mate Git API (capability
// `first-mate-git-v1`, routes under /api/v1/first-mate/features/{id}/git).
// iOS decodes only what the cover renders and tolerates missing optional
// fields, so an older or newer companion still decodes. File and commit rows
// reuse the pane Git shapes (`{status, file}` and `{hash, message}`).

/// One recorded checkout of a feature: the project checkout or an agent's
/// worktree. Checkouts that share a path appear once, with the other IDs as
/// aliases.
struct FirstMateGitCheckout: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let path: String
    var aliases: [String] = []
    var branch: String?
    var available = true

    func matches(_ workspaceID: String) -> Bool {
        id == workspaceID || aliases.contains(workspaceID)
    }

    enum CodingKeys: String, CodingKey { case id, title, path, aliases, branch, available }

    init(id: String, title: String, path: String, aliases: [String] = [], branch: String? = nil, available: Bool = true) {
        self.id = id
        self.title = title
        self.path = path
        self.aliases = aliases
        self.branch = branch
        self.available = available
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? id
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        available = try values.decodeIfPresent(Bool.self, forKey: .available) ?? true
    }
}

/// `GET …/git/workspaces`. A missing default and message mean an older
/// companion (open the project checkout); a message without a default means
/// the person must choose.
struct FirstMateGitCheckoutCatalog: Decodable, Equatable, Sendable {
    var ok: Bool
    var workspaces: [FirstMateGitCheckout]
    var defaultWorkspaceID: String?
    var selectionMessage: String?

    enum CodingKeys: String, CodingKey {
        case ok, workspaces
        case defaultWorkspaceID = "default_workspace_id"
        case selectionMessage = "selection_message"
    }

    init(ok: Bool = true, workspaces: [FirstMateGitCheckout], defaultWorkspaceID: String? = nil, selectionMessage: String? = nil) {
        self.ok = ok
        self.workspaces = workspaces
        self.defaultWorkspaceID = defaultWorkspaceID
        self.selectionMessage = selectionMessage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        workspaces = try values.decodeIfPresent([FirstMateGitCheckout].self, forKey: .workspaces) ?? []
        defaultWorkspaceID = try values.decodeIfPresent(String.self, forKey: .defaultWorkspaceID)
        selectionMessage = try values.decodeIfPresent(String.self, forKey: .selectionMessage)
    }
}

/// `GET …/git?workspace=<id>`: branch, changes and the ten newest commits.
/// `root_path` is the repository root every later call sends back as
/// `expected_root`.
struct FirstMateGitStatus: Decodable, Equatable, Sendable {
    var ok: Bool
    var rootPath: String?
    var branch: String?
    var detached: Bool?
    var staged: [WorkspaceGitFile]
    var unstaged: [WorkspaceGitFile]
    var untracked: [String]
    var commits: [WorkspaceGitCommit]

    var changeCount: Int { staged.count + unstaged.count + untracked.count }
    var isClean: Bool { changeCount == 0 }

    enum CodingKeys: String, CodingKey {
        case ok, branch, detached, staged, unstaged, untracked, commits
        case rootPath = "root_path"
    }

    init(ok: Bool = true, rootPath: String?, branch: String?, detached: Bool? = nil,
         staged: [WorkspaceGitFile] = [], unstaged: [WorkspaceGitFile] = [], untracked: [String] = [],
         commits: [WorkspaceGitCommit] = []) {
        self.ok = ok
        self.rootPath = rootPath
        self.branch = branch
        self.detached = detached
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.commits = commits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        rootPath = try values.decodeIfPresent(String.self, forKey: .rootPath)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        detached = try values.decodeIfPresent(Bool.self, forKey: .detached)
        staged = try values.decodeIfPresent([WorkspaceGitFile].self, forKey: .staged) ?? []
        unstaged = try values.decodeIfPresent([WorkspaceGitFile].self, forKey: .unstaged) ?? []
        untracked = try values.decodeIfPresent([String].self, forKey: .untracked) ?? []
        commits = try values.decodeIfPresent([WorkspaceGitCommit].self, forKey: .commits) ?? []
    }

    /// The rows of one section, untracked paths as `?` rows.
    func files(in section: GitFileSection) -> [WorkspaceGitFile] {
        switch section {
        case .staged: staged
        case .unstaged: unstaged
        case .untracked: untracked.map { WorkspaceGitFile(status: "?", file: $0) }
        }
    }

    func contains(_ file: String, in section: GitFileSection) -> Bool {
        switch section {
        case .staged: staged.contains { $0.file == file }
        case .unstaged: unstaged.contains { $0.file == file }
        case .untracked: untracked.contains(file)
        }
    }
}

/// `GET …/git/diff` (a working-tree file) and `GET …/git/commit-diff` (one
/// file of a commit) share this shape: a unified diff, capped at 64 KB.
struct FirstMateGitDiffResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var file: String?
    var diff: String
    var truncated: Bool

    enum CodingKeys: String, CodingKey { case ok, file, diff, truncated }

    init(ok: Bool = true, file: String?, diff: String, truncated: Bool = false) {
        self.ok = ok
        self.file = file
        self.diff = diff
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        file = try values.decodeIfPresent(String.self, forKey: .file)
        diff = try values.decodeIfPresent(String.self, forKey: .diff) ?? ""
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// `GET …/git/commit-files`: the files a commit changed (first parent), with
/// Git name-status letters such as `M`, `A`, `D` or `R100`.
struct FirstMateGitCommitFilesResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var hash: String?
    var files: [WorkspaceGitFile]

    enum CodingKeys: String, CodingKey { case ok, hash, files }

    init(ok: Bool = true, hash: String?, files: [WorkspaceGitFile]) {
        self.ok = ok
        self.hash = hash
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        hash = try values.decodeIfPresent(String.self, forKey: .hash)
        files = try values.decodeIfPresent([WorkspaceGitFile].self, forKey: .files) ?? []
    }
}

/// `POST …/git/stage` and `…/git/unstage`.
struct FirstMateGitMutationResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var file: String?

    enum CodingKeys: String, CodingKey { case ok, file }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        file = try values.decodeIfPresent(String.self, forKey: .file)
    }
}

/// The body of a stage or unstage request. `expected_root` is the status
/// snapshot's root: the companion refuses the change if the checkout moved.
struct FirstMateGitFileRequest: Encodable, Sendable {
    let workspace: String
    let file: String
    let expectedRoot: String

    enum CodingKeys: String, CodingKey {
        case workspace, file
        case expectedRoot = "expected_root"
    }
}
