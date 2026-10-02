import Foundation
import Observation

/// Paths belong to the companion. Never resolve them against the Mac's filesystem.
@MainActor
@Observable
final class FirstMateFolderBrowserModel: Identifiable {
    let id = UUID()
    let machineID: String
    let machineName: String

    var pathDraft: String
    var selectedEntryPath: String?
    var showHidden = false {
        didSet {
            if showHidden != oldValue { navigate(to: requestedPath) }
        }
    }
    private(set) var currentPath: String?
    private(set) var parentPath: String?
    private(set) var homePath: String?
    private(set) var entries: [FirstMateDirectoryEntry] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var hasLoadedCurrentDirectory = false

    @ObservationIgnored private let client: any FirstMateClient
    @ObservationIgnored private let isConnectionCurrent: @MainActor () -> Bool
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestedPath: String?
    @ObservationIgnored private var hasStarted = false
    private var connectionInvalidated = false
    private var retryPagination = false

    init(
        machineID: String,
        machineName: String,
        client: any FirstMateClient,
        initialPath: String? = nil,
        isConnectionCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.machineID = machineID
        self.machineName = machineName
        self.client = client
        self.requestedPath = initialPath?.isEmpty == false ? initialPath : nil
        self.pathDraft = initialPath ?? ""
        self.isConnectionCurrent = isConnectionCurrent
    }

    var isConnectionValid: Bool { !connectionInvalidated && isConnectionCurrent() }
    var canChooseCurrentFolder: Bool {
        isConnectionValid && hasLoadedCurrentDirectory && !isLoading && !isLoadingMore
            && error == nil && currentPath != nil && pathDraft == currentPath
    }
    var canOpenSelectedFolder: Bool {
        isConnectionValid && !isLoading && entries.contains { $0.path == selectedEntryPath && $0.canOpen }
    }
    var hasUnsubmittedPath: Bool { currentPath != nil && pathDraft != currentPath && !isLoading }

    func loadIfNeeded() {
        guard !hasStarted else { return }
        navigate(to: requestedPath)
    }

    @discardableResult
    func navigate(to path: String?) -> Task<Void, Never> {
        requestTask?.cancel()
        generation += 1
        hasStarted = true
        requestedPath = path
        pathDraft = path ?? ""
        selectedEntryPath = nil
        currentPath = nil
        parentPath = nil
        hasLoadedCurrentDirectory = false
        isLoadingMore = false
        retryPagination = false
        nextCursor = nil
        entries = []
        error = nil
        guard isConnectionValid else {
            invalidateConnection()
            return Task {}
        }
        isLoading = true
        return beginRequest(path: path, cursor: nil)
    }

    func goToDraft() {
        // Preserve whitespace in legitimate remote folder names.
        guard !pathDraft.isEmpty else { return }
        navigate(to: pathDraft)
    }

    func goUp() {
        guard let parentPath else { return }
        navigate(to: parentPath)
    }

    func goHome() { navigate(to: homePath) }

    func open(_ entry: FirstMateDirectoryEntry) {
        guard let current = entries.first(where: { $0.path == entry.path }), current.canOpen, isConnectionValid else { return }
        navigate(to: current.path)
    }

    func openSelectedFolder() {
        guard let entry = entries.first(where: { $0.path == selectedEntryPath }) else { return }
        open(entry)
    }

    @discardableResult
    func loadMore() -> Task<Void, Never> {
        guard !isLoading, !isLoadingMore, let currentPath, let nextCursor, hasLoadedCurrentDirectory else {
            return Task {}
        }
        guard isConnectionValid else {
            invalidateConnection()
            return Task {}
        }
        isLoadingMore = true
        error = nil
        retryPagination = true
        return beginRequest(path: currentPath, cursor: nextCursor)
    }

    @discardableResult
    func retry() -> Task<Void, Never> {
        if retryPagination { return loadMore() }
        return navigate(to: requestedPath)
    }

    func reloadCurrentFolder() { navigate(to: requestedPath) }

    /// This check is authoritative even if connection state changed since the last view update.
    func selectionPath() -> String? {
        guard isConnectionValid else {
            invalidateConnection()
            return nil
        }
        guard canChooseCurrentFolder else { return nil }
        return currentPath
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        generation += 1
        isLoading = false
        isLoadingMore = false
        hasLoadedCurrentDirectory = false
    }

    func invalidateConnection() {
        cancel()
        connectionInvalidated = true
        error = "This machine’s connection changed. Close the folder browser and open it again to reconnect."
    }

    private func beginRequest(path: String?, cursor: String?) -> Task<Void, Never> {
        let requestGeneration = generation
        let hidden = showHidden
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch(path: path, hidden: hidden, cursor: cursor, generation: requestGeneration)
        }
        requestTask = task
        return task
    }

    private func fetch(path: String?, hidden: Bool, cursor: String?, generation requestGeneration: Int) async {
        do {
            try Task.checkCancellation()
            guard isConnectionValid else {
                invalidateConnection()
                return
            }
            let response = try await client.fetchDirectories(path: path, showHidden: hidden, cursor: cursor)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard isConnectionValid else {
                invalidateConnection()
                return
            }
            guard response.ok, response.path.hasPrefix("/"), response.homePath.hasPrefix("/"),
                  response.parentPath == nil || response.parentPath?.hasPrefix("/") == true,
                  response.entries.allSatisfy({ $0.path.hasPrefix("/") }),
                  response.nextCursor == nil || response.nextCursor != cursor,
                  cursor == nil || response.path == currentPath else { throw APIError.invalidResponse }

            var seen = Set(cursor == nil ? [] : entries.map(\.path))
            let incoming = response.entries.filter { seen.insert($0.path).inserted }
            entries = cursor == nil ? incoming : entries + incoming
            currentPath = response.path
            parentPath = response.parentPath
            homePath = response.homePath
            requestedPath = response.path
            // A response must not replace a different path being typed while it loads.
            if cursor == nil, pathDraft == (path ?? "") { pathDraft = response.path }
            nextCursor = response.nextCursor
            hasLoadedCurrentDirectory = true
            error = nil
            retryPagination = false
        } catch {
            guard generation == requestGeneration else { return }
            guard isConnectionValid else {
                invalidateConnection()
                return
            }
            self.error = error is CancellationError ? "Folder loading was cancelled. Try again." : error.localizedDescription
        }
        guard generation == requestGeneration else { return }
        isLoading = false
        isLoadingMore = false
        requestTask = nil
    }
}
