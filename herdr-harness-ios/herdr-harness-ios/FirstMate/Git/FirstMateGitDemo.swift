import Foundation

/// Entirely synthetic First Mate Git for the demo app and render tests: each
/// demo feature has a project checkout and (usually) a feature worktree with
/// staged, unstaged and untracked files, recent commits and unified diffs.
/// Staging works in memory for the life of the cover. No network, no disk.
actor FirstMateGitDemoBackend: FirstMateGitBackend {
    private var repositories: [String: FirstMateGitDemo.Repository]
    private let catalog: FirstMateGitCheckoutCatalog

    init(featureID: String, featureTitle: String) {
        let checkouts = FirstMateGitDemo.checkouts(featureID: featureID, featureTitle: featureTitle)
        catalog = checkouts.catalog
        repositories = checkouts.repositories
    }

    func supportsGit() async throws -> Bool { true }

    func checkouts() async throws -> FirstMateGitCheckoutCatalog { catalog }

    func status(workspace: String) async throws -> FirstMateGitStatus {
        try repository(workspace).status
    }

    func diff(workspace: String, file: String, section: GitFileSection, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        let repository = try repository(workspace)
        guard repository.status.contains(file, in: section) else {
            throw APIError.server(status: 404, message: "File not found", code: "git_file_not_found")
        }
        let change = repository.change(for: file)
        return .init(file: file, diff: FirstMateGitDemo.workingDiff(path: file, status: section == .untracked ? "?" : change.status,
                                                                    additions: change.additions, deletions: change.deletions))
    }

    func stage(workspace: String, file: String, expectedRoot: String) async throws {
        var repository = try repository(workspace)
        repository.stage(file)
        repositories[workspace] = repository
    }

    func unstage(workspace: String, file: String, expectedRoot: String) async throws {
        var repository = try repository(workspace)
        repository.unstage(file)
        repositories[workspace] = repository
    }

    func commitFiles(workspace: String, hash: String, expectedRoot: String) async throws -> FirstMateGitCommitFilesResponse {
        let repository = try repository(workspace)
        guard let files = repository.commitFiles(hash) else { throw FirstMateGitDemo.unknownCommit(hash) }
        return .init(hash: hash, files: files.map { WorkspaceGitFile(status: $0.status, file: $0.path) })
    }

    func commitDiff(workspace: String, hash: String, file: String, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        let repository = try repository(workspace)
        guard let files = repository.commitFiles(hash) else { throw FirstMateGitDemo.unknownCommit(hash) }
        guard let change = files.first(where: { $0.path == file }) else {
            throw APIError.server(status: 404, message: "File not found in this commit", code: "git_file_not_found")
        }
        return .init(file: file, diff: FirstMateGitDemo.commitDiff(path: file, status: change.status,
                                                                   additions: change.additions, deletions: change.deletions))
    }

    private func repository(_ workspace: String) throws -> FirstMateGitDemo.Repository {
        if let repository = repositories[workspace] { return repository }
        if let checkout = catalog.workspaces.first(where: { $0.matches(workspace) }), let repository = repositories[checkout.id] {
            return repository
        }
        throw APIError.server(status: 404, message: "First Mate Git workspace not found", code: "first_mate_git_workspace_not_found")
    }
}

enum FirstMateGitDemo {
    struct Change: Equatable, Sendable {
        var status: String
        var path: String
        var additions: Int
        var deletions: Int
    }

    struct Repository: Equatable, Sendable {
        var root: String
        var branch: String
        var staged: [Change] = []
        var unstaged: [Change] = []
        var untracked: [Change] = []
        var commits: [(hash: String, subject: String)] = []
        var commitFiles: [String: [Change]] = [:]

        static func == (lhs: Repository, rhs: Repository) -> Bool {
            lhs.status == rhs.status && lhs.commitFiles == rhs.commitFiles
        }

        var status: FirstMateGitStatus {
            FirstMateGitStatus(
                rootPath: root, branch: branch, detached: false,
                staged: staged.map { WorkspaceGitFile(status: $0.status, file: $0.path) },
                unstaged: unstaged.map { WorkspaceGitFile(status: $0.status, file: $0.path) },
                untracked: untracked.map(\.path),
                commits: commits.map { WorkspaceGitCommit(hash: $0.hash, message: $0.subject) }
            )
        }

        func change(for path: String) -> Change {
            (unstaged + staged + untracked).first { $0.path == path } ?? Change(status: "M", path: path, additions: 4, deletions: 1)
        }

        /// A commit's files, matched by short or full hash. A commit the
        /// checkout's history doesn't have is nil (Git's "bad object").
        func commitFiles(_ hash: String) -> [Change]? {
            guard let listed = commits.first(where: { FirstMateGitSelectionRules.commit($0.hash, matches: hash) }) else { return nil }
            if let files = commitFiles[listed.hash] { return files }
            let type = FirstMateGitDemo.typeName(branch.split(separator: "/").last.map(String.init) ?? branch)
            return [Change(status: "M", path: "Sources/\(type)/\(type)View.swift", additions: 8, deletions: 3)]
        }

        mutating func stage(_ path: String) {
            if let index = unstaged.firstIndex(where: { $0.path == path }) {
                let change = unstaged.remove(at: index)
                if let existing = staged.firstIndex(where: { $0.path == path }) {
                    staged[existing].additions += change.additions
                    staged[existing].deletions += change.deletions
                } else {
                    staged.append(change)
                }
            } else if let index = untracked.firstIndex(where: { $0.path == path }) {
                var change = untracked.remove(at: index)
                change.status = "A"
                staged.append(change)
            }
        }

        mutating func unstage(_ path: String) {
            guard let index = staged.firstIndex(where: { $0.path == path }) else { return }
            var change = staged.remove(at: index)
            if change.status == "A" {
                change.status = "?"
                untracked.insert(change, at: 0)
            } else {
                unstaged.insert(change, at: 0)
            }
        }
    }

    // MARK: Checkouts per demo feature

    static func checkouts(featureID: String, featureTitle: String) -> (catalog: FirstMateGitCheckoutCatalog, repositories: [String: Repository]) {
        let projectRoot = "/workspace/sample-app"
        let project = Repository(root: projectRoot, branch: "main", commits: baseHistory)
        func worktree(_ slug: String, _ repository: Repository) -> (FirstMateGitCheckoutCatalog, [String: Repository]) {
            // The Mac demo's worker checkout ID; workflow commit receipts pin it.
            let id = "demo-worker"
            return (
                FirstMateGitCheckoutCatalog(workspaces: [
                    FirstMateGitCheckout(id: id, title: "Feature branch · \(repository.branch)", path: repository.root,
                                         branch: repository.branch),
                    FirstMateGitCheckout(id: "project", title: "Project checkout · main", path: projectRoot, branch: "main"),
                ], defaultWorkspaceID: id),
                [id: repository, "project": project]
            )
        }
        func projectOnly(_ repository: Repository) -> (FirstMateGitCheckoutCatalog, [String: Repository]) {
            (FirstMateGitCheckoutCatalog(workspaces: [
                FirstMateGitCheckout(id: "project", title: "Project checkout · \(repository.branch)", path: repository.root,
                                     branch: repository.branch),
            ], defaultWorkspaceID: "project"), ["project": repository])
        }
        let root = { (slug: String) in "\(projectRoot)/.worktrees/\(slug)" }

        switch featureID {
        case "demo-receipts":
            return worktree("receipt-export", Repository(
                root: root("receipt-export"), branch: "feature/receipt-export",
                staged: [.init(status: "M", path: "Sources/Receipts/ExportButton.swift", additions: 6, deletions: 2)],
                unstaged: [.init(status: "M", path: "Sources/Receipts/ReceiptExporter.swift", additions: 4, deletions: 1),
                           .init(status: "M", path: "Tests/ReceiptExportUITests.swift", additions: 7, deletions: 2)],
                untracked: [.init(status: "?", path: "Docs/qa-failure-log.md", additions: 9, deletions: 0)],
                // Short hashes, as `git log --format=%h` lists them. The demo
                // Workflow's commit receipts carry the full SHAs.
                commits: [("c81d5e9", "Add the iPad export UI test"), ("3c9e1f2", "Address review notes on the export sheet"),
                          ("7b2e0d4", "Add the Export button to the toolbar"), ("a3f9c21", "Build the month export PDF"),
                          ("5d02b7e", "Plan the receipt export")] + baseHistory,
                commitFiles: [
                    "c81d5e9": [.init(status: "A", path: "Tests/ReceiptExportUITests.swift", additions: 22, deletions: 0)],
                    "3c9e1f2": [.init(status: "M", path: "Sources/Receipts/ExportSheet.swift", additions: 6, deletions: 3),
                                .init(status: "M", path: "Sources/Receipts/ExportButton.swift", additions: 2, deletions: 1)],
                    "7b2e0d4": [.init(status: "M", path: "Sources/Receipts/ExportButton.swift", additions: 18, deletions: 3),
                                .init(status: "M", path: "Sources/Receipts/ReceiptsToolbar.swift", additions: 5, deletions: 1)],
                    "a3f9c21": [.init(status: "A", path: "Sources/Receipts/ReceiptExporter.swift", additions: 64, deletions: 0)],
                ]
            ))
        case "demo-release":
            return worktree("release-checklist", Repository(
                root: root("release-checklist"), branch: "feature/release-checklist",
                unstaged: [.init(status: "M", path: "Sources/Release/ChecklistView.swift", additions: 9, deletions: 4)],
                commits: [("3f6c2d8", "Move the approval step into its own section"),
                          ("e4b7a10", "Prototype the three-section checklist")] + baseHistory
            ))
        case "demo-search":
            return worktree("review-search", Repository(
                root: root("review-search"), branch: "feature/review-search",
                commits: [("6a2d9e1", "Address review notes on indexing"), ("0c4f8aa", "Add the sidebar search field"),
                          ("b19e7c3", "Index review evidence on launch")] + baseHistory
            ))
        case "demo-quiet":
            return worktree("quiet-notifications", Repository(
                root: root("quiet-notifications"), branch: "feature/quiet-notifications",
                unstaged: [.init(status: "M", path: "Sources/Settings/NotificationSettings.swift", additions: 14, deletions: 6)],
                untracked: [.init(status: "?", path: "Sources/Settings/QuietMode.swift", additions: 12, deletions: 0)],
                commits: [("d7e21b4", "Sketch quieter notification defaults")] + baseHistory
            ))
        case "demo-offline":
            return worktree("offline-sync", Repository(
                root: root("offline-sync"), branch: "feature/offline-sync",
                commits: [("8a61e5c", "Revision 3: retry conflicts once"), ("f03c7d1", "Merge offline edits field by field"),
                          ("4be9a02", "Add the sync engine")] + baseHistory
            ))
        case "demo-widgets":
            return projectOnly(Repository(root: projectRoot, branch: "feature/home-widgets", commits: baseHistory))
        case "demo-launch":
            return projectOnly(Repository(root: projectRoot, branch: "main",
                                          commits: [("91ac3f0", "Merge Workspace launch polish"),
                                                    ("2c7f9b0", "Draw the first-workspace empty state"),
                                                    ("44d1e8b", "Bump the build number")]))
        default:
            let slug = slug(featureTitle.isEmpty ? featureID : featureTitle)
            let type = typeName(featureTitle.isEmpty ? featureID : featureTitle)
            return worktree(slug, Repository(
                root: root(slug), branch: "feature/\(slug)",
                unstaged: [.init(status: "M", path: "Sources/\(type)/\(type)View.swift", additions: 6, deletions: 2)],
                commits: [("e2d4c6a", "Start \(featureTitle.isEmpty ? "the feature" : featureTitle)")] + baseHistory
            ))
        }
    }

    /// What the companion answers for a commit the checkout lacks
    /// (`git diff-tree` fails with "bad object").
    static func unknownCommit(_ hash: String) -> APIError {
        .server(status: 422, message: "fatal: bad object \(hash)", code: "git_failed")
    }

    static let baseHistory: [(hash: String, subject: String)] = [
        ("91ac3f0", "Merge Workspace launch polish"), ("44d1e8b", "Bump the build number"),
    ]

    // MARK: Diffs

    /// The working-tree diff of a demo file, as `git diff` prints it.
    static func workingDiff(path: String, status: String, additions: Int, deletions: Int) -> String {
        if let authored = authored[path] { return header(path, status: status) + authored.joined(separator: "\n") + "\n" }
        return generic(path: path, status: status, additions: additions, deletions: deletions)
    }

    /// A commit's diff of one file, as `git show` prints it.
    static func commitDiff(path: String, status: String, additions: Int, deletions: Int) -> String {
        generic(path: path, status: FirstMateGitStatusLetter.letter(status), additions: additions, deletions: deletions)
    }

    private static func header(_ path: String, status: String) -> String {
        let letter = FirstMateGitStatusLetter.letter(status)
        if letter == "A" || letter == "?" {
            return "diff --git a/\(path) b/\(path)\nnew file mode 100644\nindex 0000000..3c4d5e6\n--- /dev/null\n+++ b/\(path)\n"
        }
        return "diff --git a/\(path) b/\(path)\nindex 1a2b3c4..5d6e7f8 100644\n--- a/\(path)\n+++ b/\(path)\n"
    }

    private static func generic(path: String, status: String, additions: Int, deletions: Int) -> String {
        let name = typeName(FirstMateGitPath(path).name.split(separator: ".").first.map(String.init) ?? "Demo")
        var lines: [String]
        if path.hasSuffix(".md") {
            lines = ["@@ -0,0 +1,\(markdown.count) @@"] + markdown.map { "+" + $0 }
        } else if status == "A" || status == "?" {
            let body = ["import SwiftUI", "", "struct \(name): View {", "    var body: some View {",
                        "        VStack(alignment: .leading) {"]
                + newSwift.prefix(4).map { "    " + $0 } + ["        }", "    }", "}"]
            lines = ["@@ -0,0 +1,\(body.count) @@"] + body.map { "+" + $0 }
        } else {
            let removed = oldSwift.prefix(min(max(deletions, 0), 4))
            let added = newSwift.prefix(min(max(additions, 1), 10))
            lines = ["@@ -24,\(4 + removed.count) +24,\(4 + added.count) @@ struct \(name)",
                     "     var body: some View {", "         VStack(alignment: .leading) {"]
                + removed.map { "-" + $0 } + added.map { "+" + $0 } + ["         }", "     }"]
        }
        return header(path, status: status) + lines.joined(separator: "\n") + "\n"
    }

    private static let authored: [String: [String]] = [
        "Sources/Receipts/ExportButton.swift": [
            "@@ -14,9 +14,13 @@ struct ExportButton: View {",
            "     @Binding var isExporting: Bool",
            "     let month: ReceiptMonth",
            " ",
            "     var body: some View {",
            "         Button(\"Export\", systemImage: \"square.and.arrow.up\") {",
            "             isExporting = true",
            "         }",
            "-        .sheet(isPresented: $isExporting) {",
            "-            ShareSheet(items: [month.pdfURL])",
            "+        // iPad needs an anchor for the share sheet.",
            "+        .popover(isPresented: $isExporting,",
            "+                 attachmentAnchor: .rect(.bounds)) {",
            "+            ShareSheet(items: [month.pdfURL])",
            "+                .presentationCompactAdaptation(.sheet)",
            "+                .accessibilityIdentifier(\"export-share-sheet\")",
            "         }",
            "     }",
            " }",
        ],
        "Sources/Receipts/ReceiptExporter.swift": [
            "@@ -41,7 +41,10 @@ final class ReceiptExporter {",
            "     func makePDF(for month: ReceiptMonth) async throws -> URL {",
            "         let receipts = try await store.receipts(in: month)",
            "-        let data = renderer.render(receipts)",
            "+        let data = renderer.render(receipts, groupedBy: .day)",
            "+        guard !data.isEmpty else {",
            "+            throw ExportError.emptyMonth(month)",
            "+        }",
            "         let url = folder.appending(path: month.fileName)",
            "         try data.write(to: url, options: .atomic)",
            "         return url",
            "     }",
        ],
        "Tests/ReceiptExportUITests.swift": [
            "@@ -22,8 +22,13 @@ final class ReceiptExportUITests: XCTestCase {",
            "     func testExportShowsShareSheet() throws {",
            "         let app = XCUIApplication()",
            "         app.launch()",
            "-        app.buttons[\"Export\"].tap()",
            "-        XCTAssertTrue(app.otherElements[\"ShareSheet\"].waitForExistence(timeout: 30))",
            "+        app.buttons[\"September\"].tap()",
            "+        app.buttons[\"Export\"].tap()",
            "+        let sheet = app.otherElements[\"export-share-sheet\"]",
            "+        XCTAssertTrue(sheet.waitForExistence(timeout: 10),",
            "+                      \"The share sheet should appear on iPhone and iPad\")",
            "+        sheet.buttons[\"Close\"].tap()",
            "+        XCTAssertFalse(sheet.exists)",
            "     }",
            " }",
        ],
    ]

    private static let markdown = [
        "# QA failure log", "", "Run 2 of 2 on iPad (example data).", "",
        "- Tapped Export at 11:14", "- Waited 30 s for the share sheet",
        "- The sheet never appeared, so the test timed out", "", "iPhone passed both runs.",
    ]
    private static let oldSwift = ["        Text(title)", "            .font(.body)", "            .padding()", "        Spacer()"]
    private static let newSwift = [
        "        Text(title)", "            .font(.headline)", "            .foregroundStyle(.primary)",
        "            .padding(.vertical, 12)", "        Toggle(\"Quiet hours\", isOn: $quietHours)",
        "            .accessibilityHint(\"Holds routine updates until morning\")", "        Text(detail)",
        "            .font(.footnote)", "            .foregroundStyle(.secondary)", "        Spacer(minLength: 8)",
    ]

    static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "demo-feature" : words.prefix(4).joined(separator: "-")
    }

    static func typeName(_ title: String) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }
        let name = words.prefix(3).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return name.isEmpty ? "Demo" : name
    }
}
