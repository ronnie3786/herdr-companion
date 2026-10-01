import Foundation
import Observation

/// State of one First Mate Git cover: the feature's checkouts, the selected
/// checkout's status, the selection, and cached diffs. Loads run in tasks the
/// store owns, so switching rows or pushing a diff never cancels a request
/// another row is waiting on.
@MainActor @Observable
final class FirstMateGitStore {
    enum Phase: Equatable {
        case loading
        /// The companion predates `first-mate-git-v1`.
        case unsupported
        case failed(String)
        case ready
    }

    enum StatusPhase: Equatable {
        case idle
        case loading
        case loaded
        /// The checkout exists but is not a Git repository.
        case noRepository
        /// The checkout's folder is gone or no longer belongs to the feature.
        case unavailable(String)
        case failed(String)
    }

    enum LoadState<Value: Equatable>: Equatable {
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? {
            if case let .loaded(value) = self { return value }
            return nil
        }
    }

    struct DiffKey: Hashable { let path: String; let section: GitFileSection }
    struct CommitDiffKey: Hashable { let hash: String; let path: String }

    /// A file diff and the status generation it was requested for. An entry
    /// from an older generation is shown until its refresh arrives.
    struct DiffEntry: Equatable {
        var state: LoadState<FirstMateGitParsedDiff>
        var generation: Int
    }

    static let countPrefetchLimit = 40
    static let commitDiffPrefetchLimit = 12

    let pinnedCheckoutID: String?
    private(set) var phase = Phase.loading
    private(set) var catalog: FirstMateGitCheckoutCatalog?
    private(set) var selectedCheckoutID: String
    private(set) var status: FirstMateGitStatus?
    private(set) var statusPhase = StatusPhase.idle
    private(set) var selection: FirstMateGitSelection?
    private(set) var isMutating = false
    private(set) var isRefreshing = false
    /// A transient problem shown above the list: a failed stage or refresh.
    var notice: String?
    private(set) var diffs: [DiffKey: DiffEntry] = [:]
    private(set) var commitFiles: [String: LoadState<[WorkspaceGitFile]>] = [:]
    private(set) var commitDiffs: [CommitDiffKey: LoadState<FirstMateGitParsedDiff>] = [:]
    /// Commits the selected checkout doesn't have (a receipt from another
    /// checkout, or history Git no longer keeps).
    private(set) var missingCommits: Set<String> = []

    @ObservationIgnored private(set) var backend: (any FirstMateGitBackend)?
    @ObservationIgnored private var pendingCommitSHA: String?
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var checkoutGeneration = 0
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private(set) var hasStarted = false

    init(pinnedCheckoutID: String? = nil, commitSHA: String? = nil) {
        self.pinnedCheckoutID = pinnedCheckoutID
        selectedCheckoutID = pinnedCheckoutID ?? ""
        pendingCommitSHA = commitSHA
    }

    // MARK: Derived

    var isPinned: Bool { pinnedCheckoutID != nil }
    var selectedCheckout: FirstMateGitCheckout? { catalog?.workspaces.first { $0.matches(selectedCheckoutID) } }
    var showsCheckoutPicker: Bool { phase == .ready && !isPinned && (catalog?.workspaces.isEmpty == false) }
    var expectedRoot: String? { status?.rootPath ?? selectedCheckout?.path }

    func diff(path: String, section: GitFileSection) -> LoadState<FirstMateGitParsedDiff>? {
        diffs[DiffKey(path: path, section: section)]?.state
    }

    /// The +/− counts of a listed file, once its diff has been read.
    func counts(path: String, section: GitFileSection) -> (additions: Int, deletions: Int)? {
        diff(path: path, section: section)?.value.map { ($0.additions, $0.deletions) }
    }

    func commitSubject(_ hash: String) -> String? {
        status?.commits.first { FirstMateGitSelectionRules.commit($0.hash, matches: hash) }?.message
    }

    func commitDiff(hash: String, path: String) -> LoadState<FirstMateGitParsedDiff>? {
        commitDiffs[CommitDiffKey(hash: hash, path: path)]
    }

    // MARK: Loading

    /// Reads the capability, the checkouts and the selected checkout, then the
    /// selection's diff. Safe to call again (Try again).
    func start(backend: (any FirstMateGitBackend)?) async {
        hasStarted = true
        self.backend = backend
        await reload()
    }

    /// Refresh: re-reads the checkouts (keeping the chosen one) and the status.
    func reload() async {
        guard let backend else {
            phase = .failed("This feature’s machine isn’t connected. Check it in Settings, then try again.")
            return
        }
        let firstLoad = phase != .ready
        if firstLoad { phase = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard try await backend.supportsGit() else {
                phase = .unsupported
                return
            }
            let catalog = try await backend.checkouts()
            self.catalog = catalog
            if firstLoad, selectedCheckoutID.isEmpty || isPinned {
                selectedCheckoutID = FirstMateGitSelectionRules.initialCheckoutID(catalog: catalog, pinned: pinnedCheckoutID)
            }
            phase = .ready
        } catch {
            if firstLoad { phase = .failed(Self.message(error)) } else { notice = Self.message(error) }
            return
        }
        await loadStatus()
    }

    func selectCheckout(_ id: String) async {
        guard !isPinned, id != selectedCheckoutID else { return }
        selectedCheckoutID = id
        checkoutGeneration &+= 1
        prefetch?.cancel()
        status = nil
        selection = nil
        statusPhase = .idle
        diffs = [:]
        commitFiles = [:]
        commitDiffs = [:]
        missingCommits = []
        notice = nil
        await loadStatus()
    }

    func loadStatus(preferred: [GitFileSection] = []) async {
        guard let backend, selectedCheckout != nil else { return }
        let checkoutID = selectedCheckoutID, checkout = checkoutGeneration
        if status == nil { statusPhase = .loading }
        do {
            let fresh = try await backend.status(workspace: checkoutID)
            guard checkout == checkoutGeneration else { return }
            status = fresh
            statusGeneration &+= 1
            statusPhase = .loaded
            if let commitSHA = pendingCommitSHA {
                pendingCommitSHA = nil
                selection = FirstMateGitSelectionRules.initialSelection(status: fresh, commitSHA: commitSHA)
            } else {
                selection = FirstMateGitSelectionRules.reconcile(selection, status: fresh, preferred: preferred)
            }
        } catch {
            guard checkout == checkoutGeneration, !Self.isCancellation(error) else { return }
            status = nil
            selection = nil
            statusPhase = Self.statusPhase(for: error)
            return
        }
        await loadSelectionContent()
        schedulePrefetch()
    }

    /// Selects a row and reads what the diff side needs.
    func select(_ selection: FirstMateGitSelection) {
        self.selection = selection
        Task { await loadSelectionContent() }
    }

    func loadSelectionContent() async {
        switch selection {
        case let .file(path, section): await loadDiff(path: path, section: section)
        case let .commit(hash): await loadCommit(hash)
        case nil: break
        }
    }

    /// Reads every listed file's diff, one at a time, so the list can show
    /// +/− counts. The selected file was read first.
    func prefetchCounts() async {
        guard let status else { return }
        let generation = statusGeneration
        let keys = GitFileSection.allCases.flatMap { section in
            status.files(in: section).map { DiffKey(path: $0.file, section: section) }
        }
        for key in keys.prefix(Self.countPrefetchLimit) {
            guard !Task.isCancelled, generation == statusGeneration else { return }
            await loadDiff(path: key.path, section: key.section)
        }
    }

    func loadDiff(path: String, section: GitFileSection) async {
        guard let backend, let root = expectedRoot else { return }
        let key = DiffKey(path: path, section: section)
        let generation = statusGeneration, checkout = checkoutGeneration
        if let entry = diffs[key], entry.generation == generation {
            guard case .failed = entry.state else { return }
        }
        // Keep a stale diff visible while its refresh runs.
        if let entry = diffs[key], entry.state.value != nil {
            diffs[key]?.generation = generation
        } else {
            diffs[key] = DiffEntry(state: .loading, generation: generation)
        }
        do {
            let response = try await backend.diff(workspace: selectedCheckoutID, file: path, section: section, expectedRoot: root)
            guard checkout == checkoutGeneration else { return }
            diffs[key] = DiffEntry(state: .loaded(FirstMateGitParsedDiff(unified: response.diff, truncated: response.truncated)),
                                   generation: generation)
        } catch {
            guard checkout == checkoutGeneration else { return }
            if Self.isCancellation(error) {
                diffs[key]?.generation = -1
                if diffs[key]?.state == .loading { diffs[key] = nil }
            } else {
                diffs[key] = DiffEntry(state: .failed(Self.message(error)), generation: generation)
            }
        }
    }

    func loadCommit(_ hash: String) async {
        guard let backend, let root = expectedRoot else { return }
        let checkout = checkoutGeneration
        if commitFiles[hash] == nil || commitFiles[hash].map(Self.isFailed) == true {
            commitFiles[hash] = .loading
            missingCommits.remove(hash)
            do {
                let response = try await backend.commitFiles(workspace: selectedCheckoutID, hash: hash, expectedRoot: root)
                guard checkout == checkoutGeneration else { return }
                commitFiles[hash] = .loaded(response.files)
            } catch {
                guard checkout == checkoutGeneration else { return }
                if Self.isCancellation(error) {
                    commitFiles[hash] = nil
                } else if Self.isMissingCommit(error) {
                    missingCommits.insert(hash)
                    commitFiles[hash] = .failed("Commit not found")
                } else {
                    commitFiles[hash] = .failed(Self.message(error))
                }
                return
            }
        }
        guard let files = commitFiles[hash]?.value else { return }
        for file in files.prefix(Self.commitDiffPrefetchLimit) {
            await loadCommitDiff(hash: hash, path: file.file)
        }
    }

    func requestCommitDiff(hash: String, path: String) {
        guard commitDiffs[CommitDiffKey(hash: hash, path: path)] == nil else { return }
        Task { await loadCommitDiff(hash: hash, path: path) }
    }

    func loadCommitDiff(hash: String, path: String) async {
        guard let backend, let root = expectedRoot else { return }
        let key = CommitDiffKey(hash: hash, path: path), checkout = checkoutGeneration
        if let state = commitDiffs[key], !Self.isFailed(state) { return }
        commitDiffs[key] = .loading
        do {
            let response = try await backend.commitDiff(workspace: selectedCheckoutID, hash: hash, file: path, expectedRoot: root)
            guard checkout == checkoutGeneration else { return }
            commitDiffs[key] = .loaded(FirstMateGitParsedDiff(unified: response.diff, truncated: response.truncated))
        } catch {
            guard checkout == checkoutGeneration else { return }
            commitDiffs[key] = Self.isCancellation(error) ? nil : .failed(Self.message(error))
        }
    }

    // MARK: Staging

    /// Runs a row's checkbox: stage an unstaged or untracked file, unstage a
    /// staged one. Every checkbox is disabled until the change and the
    /// refresh after it finish. The toggled file stays selected in its new
    /// section, as on the Mac and web.
    func toggleStage(path: String, section: GitFileSection) async {
        guard !isMutating, let backend, let root = expectedRoot else { return }
        let action = FirstMateGitSelectionRules.stageAction(for: section)
        isMutating = true
        defer { isMutating = false }
        notice = nil
        do {
            switch action {
            case .stage: try await backend.stage(workspace: selectedCheckoutID, file: path, expectedRoot: root)
            case .unstage: try await backend.unstage(workspace: selectedCheckoutID, file: path, expectedRoot: root)
            }
        } catch {
            guard !Self.isCancellation(error) else { return }
            notice = "Couldn’t \(action.title.lowercased()) \(FirstMateGitPath(path).name). \(Self.message(error))"
            // A moved checkout refuses changes until the status is re-read.
            await loadStatus()
            return
        }
        selection = .file(path: path, section: section)
        await loadStatus(preferred: FirstMateGitSelectionRules.sectionsAfter(action))
    }

    private func schedulePrefetch() {
        prefetch?.cancel()
        prefetch = Task { [weak self] in await self?.prefetchCounts() }
    }

    // MARK: Errors

    private static func isFailed<Value>(_ state: LoadState<Value>) -> Bool {
        if case .failed = state { return true }
        return false
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    nonisolated static func message(_ error: any Error) -> String {
        if let error = error as? APIError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }

    nonisolated static func statusPhase(for error: any Error) -> StatusPhase {
        switch (error as? APIError)?.serverCode {
        case "git_repository_not_found": .noRepository
        case "first_mate_git_workspace_not_found", "workspace_root_not_found", "invalid_workspace_root":
            .unavailable(message(error))
        default: .failed(message(error))
        }
    }

    /// Git refuses an unknown object (`git_failed`, 422), the companion
    /// refuses a malformed hash (400), and a gone commit can read as 404.
    nonisolated static func isMissingCommit(_ error: any Error) -> Bool {
        guard case let .server(status, message)? = error as? APIError else { return false }
        if let code = message.code { return ["git_failed", "invalid_git_hash", "git_commit_not_found"].contains(code) }
        return status == 404 || status == 422
    }
}
