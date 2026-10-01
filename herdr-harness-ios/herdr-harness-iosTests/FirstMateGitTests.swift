import Foundation
import Synchronization
import Testing
@testable import herdr_harness_ios

// Synthetic data only: example paths, hashes and feature IDs.

@Suite("First Mate Git decoding")
struct FirstMateGitDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("The checkout catalog keeps aliases, branch, availability, default and message")
    func catalog() throws {
        let catalog = try decode(FirstMateGitCheckoutCatalog.self, """
        {"ok":true,"workspaces":[
          {"id":"project","path":"/workspace/sample-app","available":true,"branch":"main","upstream":"refs/remotes/origin/main",
           "target_branch":"origin/main","aliases":["a-1"],"title":"Project checkout · main"},
          {"id":"a-2","path":"/workspace/sample-app/.worktrees/x","available":false,"aliases":[],
           "title":"x (unavailable)"}],
         "default_workspace_id":null,
         "selection_message":"Choose the checkout to review."}
        """)
        #expect(catalog.ok)
        #expect(catalog.workspaces.map(\.id) == ["project", "a-2"])
        #expect(catalog.workspaces[0].matches("a-1"))
        #expect(catalog.workspaces[0].branch == "main")
        #expect(catalog.workspaces[1].available == false)
        #expect(catalog.workspaces[1].branch == nil)
        #expect(catalog.defaultWorkspaceID == nil)
        #expect(catalog.selectionMessage == "Choose the checkout to review.")
    }

    @Test("An older companion's catalog decodes with defaults")
    func olderCatalog() throws {
        let catalog = try decode(FirstMateGitCheckoutCatalog.self,
                                 #"{"ok":true,"workspaces":[{"id":"project","title":"Project","path":"/workspace/sample-app"}]}"#)
        #expect(catalog.workspaces.first?.aliases == [])
        #expect(catalog.workspaces.first?.available == true)
        #expect(catalog.defaultWorkspaceID == nil && catalog.selectionMessage == nil)
        #expect(FirstMateGitSelectionRules.initialCheckoutID(catalog: catalog, pinned: nil) == "project")
    }

    @Test("Status decodes the companion's payload and tolerates missing lists")
    func status() throws {
        let status = try decode(FirstMateGitStatus.self, """
        {"ok":true,"feature_id":"feature-1","workspace":"project","root_path":"/workspace/sample-app","branch":"feature/x",
         "detached":null,"staged":[{"status":"A","file":"Sources/New.swift"}],"unstaged":[{"status":"M","file":"README.md"}],
         "untracked":["Docs/notes.md"],"commits":[{"hash":"1a2b3c4","message":"Add the thing"}],"generated_at":"2030-01-01T00:00:00Z"}
        """)
        #expect(status.rootPath == "/workspace/sample-app")
        #expect(status.branch == "feature/x" && status.detached == nil)
        #expect(status.staged == [WorkspaceGitFile(status: "A", file: "Sources/New.swift")])
        #expect(status.unstaged.map(\.file) == ["README.md"])
        #expect(status.untracked == ["Docs/notes.md"])
        #expect(status.commits == [WorkspaceGitCommit(hash: "1a2b3c4", message: "Add the thing")])
        #expect(status.changeCount == 3 && !status.isClean)
        #expect(status.files(in: .untracked) == [WorkspaceGitFile(status: "?", file: "Docs/notes.md")])

        let bare = try decode(FirstMateGitStatus.self, #"{"ok":true}"#)
        #expect(bare.isClean && bare.commits.isEmpty && bare.rootPath == nil)
    }

    @Test("Diff, commit files, commit diff and mutation responses decode")
    func diffsAndMutations() throws {
        let diff = try decode(FirstMateGitDiffResponse.self, """
        {"ok":true,"feature_id":"f","workspace":"w","file":"a.swift","section":"staged","diff":"@@ -1 +1 @@\\n-a\\n+b\\n","truncated":true}
        """)
        #expect(diff.file == "a.swift" && diff.truncated)
        #expect(FirstMateGitParsedDiff(unified: diff.diff).additions == 1)

        let files = try decode(FirstMateGitCommitFilesResponse.self, """
        {"ok":true,"feature_id":"f","workspace":"w","hash":"abc1234","files":[{"status":"R100","file":"New.swift"},{"status":"D","file":"Old.swift"}]}
        """)
        #expect(files.hash == "abc1234")
        #expect(files.files.map(\.status) == ["R100", "D"])
        #expect(FirstMateGitStatusLetter.letter("R100") == "R")

        let commitDiff = try decode(FirstMateGitDiffResponse.self, #"{"ok":true,"hash":"abc1234","file":"New.swift","diff":""}"#)
        #expect(commitDiff.diff.isEmpty && !commitDiff.truncated)

        let mutation = try decode(FirstMateGitMutationResponse.self, #"{"ok":true,"feature_id":"f","workspace":"w","file":"a.swift"}"#)
        #expect(mutation.ok && mutation.file == "a.swift")
    }
}

@Suite("First Mate Git unified diff parsing")
struct FirstMateGitDiffParsingTests {
    @Test("Line numbers follow each hunk; headers are skipped; counts add up")
    func numbers() {
        let diff = FirstMateGitParsedDiff(unified: """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1a2b3c4..5d6e7f8 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -41,4 +41,5 @@ final class A {
             let a = 1
        -    let b = 2
        +    let b = 3
        +\tlet c = 4
             return a
        \\ No newline at end of file
        @@ -90,2 +91,2 @@
        -old
        +new

        """)
        #expect(diff.additions == 3 && diff.deletions == 2)
        let kinds = diff.lines.map(\.kind)
        #expect(kinds == [.hunk, .context, .removed, .added, .added, .context, .note, .hunk, .removed, .added])
        #expect(diff.lines[1].oldNumber == 41 && diff.lines[1].newNumber == 41)
        #expect(diff.lines[2].oldNumber == 42 && diff.lines[2].newNumber == nil)
        #expect(diff.lines[3].newNumber == 42 && diff.lines[4].newNumber == 43)
        #expect(diff.lines[4].text == "    let c = 4")
        #expect(diff.lines[5].oldNumber == 43 && diff.lines[5].newNumber == 44)
        #expect(diff.lines[6].text == "No newline at end of file")
        #expect(diff.lines[8].oldNumber == 90 && diff.lines[9].newNumber == 91)
        #expect(FirstMateGitParsedDiff.hunkStarts("@@ -0,0 +1,9 @@").map { [$0.old, $0.new] } == [0, 1])
        #expect(FirstMateGitParsedDiff.hunkStarts("not a hunk") == nil)
    }

    @Test("Binary and empty diffs")
    func binaryAndEmpty() {
        let binary = FirstMateGitParsedDiff(unified: "diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n")
        #expect(binary.lines.map(\.kind) == [.note])
        #expect(FirstMateGitParsedDiff(unified: "").isEmpty)
        #expect(FirstMateGitPath("Sources/Receipts/Export.swift") == FirstMateGitPath("Sources/Receipts/Export.swift"))
        #expect(FirstMateGitPath("Sources/Receipts/Export.swift").name == "Export.swift")
        #expect(FirstMateGitPath("Sources/Receipts/Export.swift").directory == "Sources/Receipts")
        #expect(FirstMateGitPath("README.md").directory.isEmpty)
    }
}

@Suite("First Mate Git selection and staging rules")
struct FirstMateGitSelectionRulesTests {
    private let status = FirstMateGitStatus(
        rootPath: "/workspace/sample-app", branch: "feature/x",
        staged: [.init(status: "M", file: "Staged.swift")],
        unstaged: [.init(status: "M", file: "Unstaged.swift"), .init(status: "M", file: "Both.swift")],
        untracked: ["New.md"],
        commits: [.init(hash: "c81d5e9", message: "Newest"), .init(hash: "a3f9c21", message: "Older")]
    )

    @Test("Default selection: unstaged, staged, untracked, newest commit; a requested commit wins")
    func defaults() {
        typealias Rules = FirstMateGitSelectionRules
        #expect(Rules.initialSelection(status: status, commitSHA: nil) == .file(path: "Unstaged.swift", section: .unstaged))
        var only = status
        only.unstaged = []
        #expect(Rules.initialSelection(status: only, commitSHA: nil) == .file(path: "Staged.swift", section: .staged))
        only.staged = []
        #expect(Rules.initialSelection(status: only, commitSHA: nil) == .file(path: "New.md", section: .untracked))
        only.untracked = []
        #expect(Rules.initialSelection(status: only, commitSHA: nil) == .commit(hash: "c81d5e9"))
        only.commits = []
        #expect(Rules.initialSelection(status: only, commitSHA: nil) == nil)
        // A workflow receipt's full SHA selects the listed short hash.
        #expect(Rules.initialSelection(status: status, commitSHA: "A3F9C21E5B7D4C10") == .commit(hash: "a3f9c21"))
        // An unlisted commit is still selected by its own hash.
        #expect(Rules.initialSelection(status: status, commitSHA: "0123abcd") == .commit(hash: "0123abcd"))
        #expect(Rules.commit("a3f9c21", matches: "a3f9c21e5b7d4c10"))
        #expect(!Rules.commit("a3f", matches: "a3f9c21"))
        #expect(!Rules.commit("a3f9c21", matches: "a3f9c22"))
    }

    @Test("Stage boxes: staged unstages, unstaged and untracked stage")
    func stageActions() {
        #expect(FirstMateGitSelectionRules.stageAction(for: .staged) == .unstage)
        #expect(FirstMateGitSelectionRules.stageAction(for: .unstaged) == .stage)
        #expect(FirstMateGitSelectionRules.stageAction(for: .untracked) == .stage)
        #expect(FirstMateGitSelectionRules.sectionsAfter(.stage) == [.staged])
        #expect(FirstMateGitSelectionRules.sectionsAfter(.unstage) == [.unstaged, .untracked])
    }

    @Test("A refresh follows a moved file, keeps commits and falls back for vanished files")
    func reconcile() {
        typealias Rules = FirstMateGitSelectionRules
        var after = status
        after.unstaged.removeAll { $0.file == "Unstaged.swift" }
        after.staged.append(.init(status: "M", file: "Unstaged.swift"))
        #expect(Rules.reconcile(.file(path: "Unstaged.swift", section: .unstaged), status: after, preferred: [.staged])
            == .file(path: "Unstaged.swift", section: .staged))
        // Partially staged: the preferred section wins over the old one.
        after.staged.append(.init(status: "M", file: "Both.swift"))
        #expect(Rules.reconcile(.file(path: "Both.swift", section: .unstaged), status: after, preferred: [.staged])
            == .file(path: "Both.swift", section: .staged))
        #expect(Rules.reconcile(.file(path: "Both.swift", section: .unstaged), status: after)
            == .file(path: "Both.swift", section: .unstaged))
        #expect(Rules.reconcile(.commit(hash: "a3f9c21"), status: after) == .commit(hash: "a3f9c21"))
        #expect(Rules.reconcile(.file(path: "Gone.swift", section: .staged), status: after)
            == .file(path: "Both.swift", section: .unstaged))
    }

    @Test("Checkout choice: pinned, recommended, older companion, ambiguous; picker groups")
    func checkouts() {
        typealias Rules = FirstMateGitSelectionRules
        let rows = [FirstMateGitCheckout(id: "project", title: "Project", path: "/p"),
                    FirstMateGitCheckout(id: "w-1", title: "One", path: "/1"),
                    FirstMateGitCheckout(id: "w-2", title: "Two", path: "/2")]
        let recommended = FirstMateGitCheckoutCatalog(workspaces: rows, defaultWorkspaceID: "w-2")
        #expect(Rules.initialCheckoutID(catalog: recommended, pinned: nil) == "w-2")
        #expect(Rules.initialCheckoutID(catalog: recommended, pinned: "w-1") == "w-1")
        let ambiguous = FirstMateGitCheckoutCatalog(workspaces: rows, selectionMessage: "Choose")
        #expect(Rules.initialCheckoutID(catalog: ambiguous, pinned: nil) == "")
        #expect(Rules.initialCheckoutID(catalog: FirstMateGitCheckoutCatalog(workspaces: rows), pinned: nil) == "project")
        let groups = Rules.pickerGroups(catalog: recommended)
        #expect(groups.primary.map(\.id) == ["w-2", "project"])
        #expect(groups.other.map(\.id) == ["w-1"])
    }
}

@MainActor
@Suite("First Mate Git store", .serialized)
struct FirstMateGitStoreTests {
    @Test("Demo: opens the recommended worktree, the first unstaged diff and every count")
    func demoOpens() async throws {
        let store = FirstMateGitStore()
        await store.start(backend: FirstMateGitDemoBackend(featureID: "demo-receipts", featureTitle: "Receipt export"))
        #expect(store.phase == .ready)
        #expect(store.selectedCheckoutID == "demo-worker")
        #expect(store.showsCheckoutPicker)
        #expect(store.statusPhase == .loaded)
        #expect(store.selection == .file(path: "Sources/Receipts/ReceiptExporter.swift", section: .unstaged))
        #expect(store.diff(path: "Sources/Receipts/ReceiptExporter.swift", section: .unstaged)?.value?.additions == 4)
        await store.prefetchCounts()
        #expect(store.counts(path: "Sources/Receipts/ExportButton.swift", section: .staged).map { [$0.additions, $0.deletions] } == [6, 2])
        #expect(store.counts(path: "Docs/qa-failure-log.md", section: .untracked)?.additions == 9)
    }

    @Test("Demo: staging and unstaging move the file and keep it selected")
    func demoStaging() async throws {
        let store = FirstMateGitStore()
        await store.start(backend: FirstMateGitDemoBackend(featureID: "demo-receipts", featureTitle: "Receipt export"))
        await store.toggleStage(path: "Sources/Receipts/ReceiptExporter.swift", section: .unstaged)
        #expect(!store.isMutating)
        #expect(store.status?.staged.map(\.file).contains("Sources/Receipts/ReceiptExporter.swift") == true)
        #expect(store.selection == .file(path: "Sources/Receipts/ReceiptExporter.swift", section: .staged))
        await store.toggleStage(path: "Docs/qa-failure-log.md", section: .untracked)
        #expect(store.status?.staged.last == WorkspaceGitFile(status: "A", file: "Docs/qa-failure-log.md"))
        #expect(store.selection == .file(path: "Docs/qa-failure-log.md", section: .staged))
        await store.toggleStage(path: "Docs/qa-failure-log.md", section: .staged)
        #expect(store.status?.untracked == ["Docs/qa-failure-log.md"])
        #expect(store.selection == .file(path: "Docs/qa-failure-log.md", section: .untracked))
        await store.toggleStage(path: "Sources/Receipts/ExportButton.swift", section: .staged)
        #expect(store.selection == .file(path: "Sources/Receipts/ExportButton.swift", section: .unstaged))
    }

    @Test("Demo: a workflow receipt's full SHA opens the commit in the pinned checkout; an unknown one is not found")
    func demoCommits() async throws {
        let store = FirstMateGitStore(pinnedCheckoutID: "demo-worker", commitSHA: "a3f9c21e5b7d4c10")
        await store.start(backend: FirstMateGitDemoBackend(featureID: "demo-receipts", featureTitle: "Receipt export"))
        #expect(!store.showsCheckoutPicker)
        #expect(store.selection == .commit(hash: "a3f9c21"))
        #expect(store.commitSubject("a3f9c21e5b7d4c10") == "Build the month export PDF")
        #expect(store.commitFiles["a3f9c21"]?.value?.map(\.file) == ["Sources/Receipts/ReceiptExporter.swift"])
        #expect(store.commitDiff(hash: "a3f9c21", path: "Sources/Receipts/ReceiptExporter.swift")?.value?.isEmpty == false)
        for sha in ["7b2e0d4a9c1f3e22", "3c9e1f2b7a4d8e31", "c81d5e9f2a6b4c47"] {
            #expect(store.commitSubject(sha) != nil)
        }

        let unknown = FirstMateGitStore(pinnedCheckoutID: "demo-worker", commitSHA: "ffffeeee11112222")
        await unknown.start(backend: FirstMateGitDemoBackend(featureID: "demo-receipts", featureTitle: "Receipt export"))
        #expect(unknown.selection == .commit(hash: "ffffeeee11112222"))
        #expect(unknown.missingCommits.contains("ffffeeee11112222"))
    }

    @Test("Demo: a clean checkout selects the newest commit; choosing a checkout resets the selection")
    func demoClean() async throws {
        let store = FirstMateGitStore()
        await store.start(backend: FirstMateGitDemoBackend(featureID: "demo-search", featureTitle: "Review search"))
        #expect(store.status?.isClean == true)
        #expect(store.selection == .commit(hash: "6a2d9e1"))
        await store.selectCheckout("project")
        #expect(store.status?.branch == "main")
        #expect(store.selection == .commit(hash: "91ac3f0"))
    }

    @Test("Unsupported companion, no machine, no repository, ambiguous catalog and a failed stage")
    func states() async throws {
        let unsupported = FirstMateGitStore()
        await unsupported.start(backend: StubGitBackend(supports: false))
        #expect(unsupported.phase == .unsupported)

        let missing = FirstMateGitStore()
        await missing.start(backend: nil)
        guard case .failed = missing.phase else { Issue.record("expected failed"); return }

        let noRepository = FirstMateGitStore()
        await noRepository.start(backend: StubGitBackend(statusError: APIError.server(
            status: 404, message: "Workspace is not inside a Git repository", code: "git_repository_not_found")))
        #expect(noRepository.statusPhase == .noRepository)

        let ambiguous = FirstMateGitStore()
        await ambiguous.start(backend: StubGitBackend(catalog: .init(workspaces: StubGitBackend.rows, selectionMessage: "Choose")))
        #expect(ambiguous.phase == .ready && ambiguous.selectedCheckoutID.isEmpty && ambiguous.status == nil)
        await ambiguous.selectCheckout("w-1")
        #expect(ambiguous.statusPhase == .loaded)

        let refused = FirstMateGitStore()
        await refused.start(backend: StubGitBackend(stageError: APIError.server(
            status: 409, message: "This pane moved to a different Git repository.", code: "git_repository_changed")))
        await refused.toggleStage(path: "A.swift", section: .unstaged)
        #expect(refused.notice?.hasPrefix("Couldn’t stage A.swift.") == true)
        #expect(!refused.isMutating)
    }
}

/// A scripted backend for the states the demo never reaches.
private struct StubGitBackend: FirstMateGitBackend {
    static let rows = [FirstMateGitCheckout(id: "project", title: "Project", path: "/workspace/sample-app"),
                       FirstMateGitCheckout(id: "w-1", title: "One", path: "/workspace/one"),
                       FirstMateGitCheckout(id: "w-2", title: "Two", path: "/workspace/two")]
    var supports = true
    var catalog = FirstMateGitCheckoutCatalog(workspaces: rows, defaultWorkspaceID: "w-1")
    var statusError: APIError?
    var stageError: APIError?

    func supportsGit() async throws -> Bool { supports }
    func checkouts() async throws -> FirstMateGitCheckoutCatalog { catalog }
    func status(workspace: String) async throws -> FirstMateGitStatus {
        if let statusError { throw statusError }
        return FirstMateGitStatus(rootPath: "/workspace/one", branch: "feature/one", unstaged: [.init(status: "M", file: "A.swift")])
    }
    func diff(workspace: String, file: String, section: GitFileSection, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        .init(file: file, diff: "@@ -1 +1 @@\n-a\n+b\n")
    }
    func stage(workspace: String, file: String, expectedRoot: String) async throws { if let stageError { throw stageError } }
    func unstage(workspace: String, file: String, expectedRoot: String) async throws { if let stageError { throw stageError } }
    func commitFiles(workspace: String, hash: String, expectedRoot: String) async throws -> FirstMateGitCommitFilesResponse {
        .init(hash: hash, files: [])
    }
    func commitDiff(workspace: String, hash: String, file: String, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        .init(file: file, diff: "")
    }
}

@Suite("First Mate Git HTTP contract", .serialized)
struct FirstMateGitHTTPContractTests {
    private func makeClient(status: Int = 200, body: String) throws -> (HerdrAPIClient, URLSession) {
        FirstMateGitHTTPProbe.state.withLock { $0 = .init(status: status, body: Data(body.utf8)) }
        let configuration = try #require(ServerConfiguration(urlString: "https://git-probe.example.invalid:9443", token: "synthetic-token"))
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [FirstMateGitHTTPProbe.self]
        let session = URLSession(configuration: options)
        return (HerdrAPIClient(configuration: configuration, session: session), session)
    }

    private var requests: [URLRequest] { FirstMateGitHTTPProbe.state.withLock { $0.requests } }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("Reads hit the feature-scoped routes with workspace and expected_root, 30 s timeouts")
    func reads() async throws {
        let (client, session) = try makeClient(body: #"{"ok":true,"workspaces":[],"files":[],"diff":""}"#)
        defer { session.invalidateAndCancel() }
        _ = try await client.fetchFirstMateGitCheckouts(featureID: "feature-1")
        _ = try await client.fetchFirstMateGitStatus(featureID: "feature-1", workspaceID: "assignment-2")
        _ = try await client.fetchFirstMateGitDiff(featureID: "feature-1", workspaceID: "project", file: "Sources/A+B.swift",
                                                   section: .untracked, expectedRoot: "/workspace/sample app")
        _ = try await client.fetchFirstMateGitCommitFiles(featureID: "feature-1", workspaceID: "project", hash: "a3f9c21",
                                                          expectedRoot: "/workspace/sample-app")
        _ = try await client.fetchFirstMateGitCommitDiff(featureID: "feature-1", workspaceID: "project", hash: "a3f9c21",
                                                         file: "README.md", expectedRoot: "/workspace/sample-app")
        let sent = requests
        #expect(sent.map { $0.url!.path } == [
            "/api/v1/first-mate/features/feature-1/git/workspaces",
            "/api/v1/first-mate/features/feature-1/git",
            "/api/v1/first-mate/features/feature-1/git/diff",
            "/api/v1/first-mate/features/feature-1/git/commit-files",
            "/api/v1/first-mate/features/feature-1/git/commit-diff",
        ])
        #expect(sent.allSatisfy { $0.httpMethod == "GET" && $0.timeoutInterval == 30 })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" })
        #expect(sent[0].url?.query == nil)
        #expect(query(sent[1]) == ["workspace": "assignment-2"])
        #expect(query(sent[2]) == ["workspace": "project", "file": "Sources/A+B.swift", "section": "untracked",
                                   "expected_root": "/workspace/sample app"])
        // The companion form-decodes queries: a literal plus would read as a space.
        #expect(sent[2].url?.query?.contains("A%2BB.swift") == true)
        #expect(query(sent[3]) == ["workspace": "project", "hash": "a3f9c21", "expected_root": "/workspace/sample-app"])
        #expect(query(sent[4]) == ["workspace": "project", "hash": "a3f9c21", "file": "README.md",
                                   "expected_root": "/workspace/sample-app"])
    }

    @Test("Stage and unstage POST workspace, file and expected_root with a 30 s timeout")
    func mutations() async throws {
        let (client, session) = try makeClient(body: #"{"ok":true,"file":"A.swift"}"#)
        defer { session.invalidateAndCancel() }
        try await client.stageFirstMateGitFile(featureID: "feature-1", workspaceID: "project", file: "A.swift",
                                               expectedRoot: "/workspace/sample-app")
        try await client.unstageFirstMateGitFile(featureID: "feature-1", workspaceID: "w-2", file: "A.swift",
                                                 expectedRoot: "/workspace/two")
        let sent = requests
        #expect(sent.map { $0.url!.path } == ["/api/v1/first-mate/features/feature-1/git/stage",
                                              "/api/v1/first-mate/features/feature-1/git/unstage"])
        #expect(sent.allSatisfy { $0.httpMethod == "POST" && $0.timeoutInterval == 30 && $0.url?.query == nil })
        let bodies = try sent.map { try JSONDecoder().decode([String: String].self, from: #require($0.httpBody)) }
        #expect(bodies == [["workspace": "project", "file": "A.swift", "expected_root": "/workspace/sample-app"],
                           ["workspace": "w-2", "file": "A.swift", "expected_root": "/workspace/two"]])
    }

    @Test("A companion without First Mate capabilities reads as unsupported; errors keep their code")
    func capabilityAndErrors() async throws {
        let (client, session) = try makeClient(status: 404, body: #"{"error":{"code":"not_found","message":"Not found"}}"#)
        defer { session.invalidateAndCancel() }
        #expect(try await FirstMateGitLiveBackend(client: client, featureID: "f").supportsGit() == false)

        let (older, olderSession) = try makeClient(body: #"{"ok":true,"capabilities":["first-mate-v1"]}"#)
        defer { olderSession.invalidateAndCancel() }
        #expect(try await FirstMateGitLiveBackend(client: older, featureID: "f").supportsGit() == false)

        let (current, currentSession) = try makeClient(body: #"{"ok":true,"capabilities":["first-mate-v1","first-mate-git-v1"]}"#)
        defer { currentSession.invalidateAndCancel() }
        #expect(try await FirstMateGitLiveBackend(client: current, featureID: "f").supportsGit())

        let (failing, failingSession) = try makeClient(
            status: 404, body: #"{"error":{"code":"git_repository_not_found","message":"Workspace is not inside a Git repository"}}"#)
        defer { failingSession.invalidateAndCancel() }
        do {
            _ = try await failing.fetchFirstMateGitStatus(featureID: "f", workspaceID: "project")
            Issue.record("expected an error")
        } catch {
            #expect(FirstMateGitStore.statusPhase(for: error) == .noRepository)
        }
    }

    @Test("Feature IDs are validated before a request is built")
    func invalidFeature() async throws {
        let (client, session) = try makeClient(body: "{}")
        defer { session.invalidateAndCancel() }
        await #expect(throws: APIError.self) { try await client.fetchFirstMateGitCheckouts(featureID: "../escape") }
        #expect(requests.isEmpty)
    }
}

private final class FirstMateGitHTTPProbe: URLProtocol {
    struct State: Sendable {
        var status = 200
        var body = Data()
        var requests: [URLRequest] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let answer = Self.state.withLock { state in
            state.requests.append(captured)
            return (state.status, state.body)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}
