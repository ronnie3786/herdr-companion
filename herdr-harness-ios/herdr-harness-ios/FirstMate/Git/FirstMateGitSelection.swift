import Foundation

/// What the diff side shows: one file of one section, or one commit.
enum FirstMateGitSelection: Hashable, Sendable {
    case file(path: String, section: GitFileSection)
    case commit(hash: String)

    var filePath: String? {
        if case let .file(path, _) = self { return path }
        return nil
    }

    var commitHash: String? {
        if case let .commit(hash) = self { return hash }
        return nil
    }
}

/// Pure selection and staging rules, shared by iPad and iPhone and tested
/// without views.
enum FirstMateGitSelectionRules {
    /// The checkbox action for a row: staged rows unstage, everything else
    /// (unstaged and untracked) stages.
    enum StageAction: Equatable, Sendable {
        case stage, unstage

        var title: String { self == .stage ? "Stage" : "Unstage" }
    }

    static func stageAction(for section: GitFileSection) -> StageAction {
        section == .staged ? .unstage : .stage
    }

    /// A short and a full hash of the same commit match (either way round, at
    /// least four characters, case-insensitive).
    static func commit(_ hash: String, matches other: String) -> Bool {
        let left = hash.lowercased(), right = other.lowercased()
        guard min(left.count, right.count) >= 4 else { return left == right }
        return left.hasPrefix(right) || right.hasPrefix(left)
    }

    /// The opening selection: a requested commit (a workflow receipt), else
    /// the first unstaged file, the first staged file, the first untracked
    /// file, then the newest commit. Nil when the checkout has nothing.
    static func initialSelection(status: FirstMateGitStatus, commitSHA: String?) -> FirstMateGitSelection? {
        if let commitSHA, !commitSHA.isEmpty {
            let listed = status.commits.first { commit($0.hash, matches: commitSHA) }
            return .commit(hash: listed?.hash ?? commitSHA)
        }
        if let file = status.unstaged.first { return .file(path: file.file, section: .unstaged) }
        if let file = status.staged.first { return .file(path: file.file, section: .staged) }
        if let file = status.untracked.first { return .file(path: file, section: .untracked) }
        if let newest = status.commits.first { return .commit(hash: newest.hash) }
        return nil
    }

    /// Keeps a selection across a refresh. A file that moved section (after
    /// staging or unstaging) is followed into `preferred`, then into any
    /// section that still lists it; a vanished file falls back to the opening
    /// rule. Commits are immutable and stay selected.
    static func reconcile(
        _ selection: FirstMateGitSelection?, status: FirstMateGitStatus, preferred: [GitFileSection] = []
    ) -> FirstMateGitSelection? {
        switch selection {
        case let .commit(hash):
            return .commit(hash: hash)
        case let .file(path, section):
            for candidate in preferred + [section] + GitFileSection.allCases where status.contains(path, in: candidate) {
                return .file(path: path, section: candidate)
            }
            return initialSelection(status: status, commitSHA: nil)
        case nil:
            return initialSelection(status: status, commitSHA: nil)
        }
    }

    /// Where a file lands after its checkbox runs: staging moves it to Staged;
    /// unstaging returns it to Unstaged, or Untracked for a new file.
    static func sectionsAfter(_ action: StageAction) -> [GitFileSection] {
        action == .stage ? [.staged] : [.unstaged, .untracked]
    }

    /// The checkout opened for a catalog. A pinned target (a workflow commit
    /// receipt in a known checkout) wins; otherwise the companion's default.
    /// A catalog from an older companion has neither default nor message and
    /// opens the project checkout. A message without a default means the
    /// feature has several checkouts and no unique feature branch: the person
    /// chooses (empty ID), never a silent fallback to the project.
    static func initialCheckoutID(catalog: FirstMateGitCheckoutCatalog, pinned: String?) -> String {
        if let pinned { return pinned }
        if let recommended = catalog.defaultWorkspaceID { return recommended }
        return catalog.selectionMessage == nil ? "project" : ""
    }

    /// The picker lists the recommended checkout and the project first; the
    /// rest go under "Other checkouts".
    static func pickerGroups(catalog: FirstMateGitCheckoutCatalog) -> (primary: [FirstMateGitCheckout], other: [FirstMateGitCheckout]) {
        let recommended = catalog.defaultWorkspaceID
        let primary = catalog.workspaces.filter { $0.id == recommended || $0.id == "project" }
            .sorted { $0.id == recommended && $1.id != recommended }
        let other = catalog.workspaces.filter { $0.id != recommended && $0.id != "project" }
        return (primary, other)
    }
}
