import Foundation
import Observation
import UniformTypeIdentifiers

struct PRReviewConnectionIdentity: Equatable {
    let configuration: ServerConfiguration?
    let generation: Int
    let isDemo: Bool
    let machineRevision: Int
}

struct PRReviewDiffRequestIdentity: Equatable, Hashable, Sendable {
    let generation: Int
    let machineID: String?
    let reviewID: String
    let path: String
    let baseSHA: String
    let headSHA: String
}

@MainActor
@Observable
final class PRReviewStore {
    private var client: (any PRReviewClient)?
    private var generation = 0
    private var machineID: String?
    private let documentResources: PRReviewDocumentResources

    private(set) var isDemo = false
    var reviews: [PRReviewSummary] = []
    var archivedReviews: [PRReviewSummary] = []
    var selectedReviewID: String?
    var snapshot: PRReviewSnapshot?
    var diff: PRReviewDiff?
    private(set) var diffLoadError: String?
    private(set) var diffLoadErrorIdentity: PRReviewDiffRequestIdentity?
    private(set) var loadingDiffIdentity: PRReviewDiffRequestIdentity?
    private(set) var completedDiffIdentity: PRReviewDiffRequestIdentity?
    var selectedPath: String?
    var tab: PRReviewTab = .files
    var viewMode: PRReviewViewMode = .github
    var impactFilter: PRReviewImpactFilter = .all
    var hideViewed = false
    var search = ""
    var showArchived = false
    var highlight: (path: String, start: Int, end: Int, side: PRReviewSide)?
    var scrollRequest: (path: String, line: Int, side: PRReviewSide, token: Int)?
    var visibleLines: (path: String, start: Int, end: Int, side: PRReviewSide)?
    var isCreating = false
    /// Sheet presentation is separate from the request-in-flight state above.
    var isPresentingStartSheet = false
    var pendingURL: String?
    var isAddingSkill = false
    var isRefreshing = false
    var hasLoaded = false
    var unsupported = false
    var error: String?
    var capabilities: PRReviewCapabilities?
    var documentUploads: [String: PRReviewDocumentUpload] = [:]
    var contextImportError: String?
    var unconfigured = false

    /// Every document resource this store has published a phase for. A
    /// connection change retires phases still marked `.downloading` so a slow
    /// download cannot leave a Context row spinning without a retry.
    @ObservationIgnored private var heldDocumentScopes: Set<PRReviewDocumentResources.Scope> = []
    /// Window-lifetime cache protections handed out through this store.
    @ObservationIgnored private var documentLeases: [ObjectIdentifier: PRReviewDocumentLease] = [:]

    /// Download phases for the currently configured machine and review. The
    /// state itself is shared, so a document downloaded through a popped-out
    /// window still publishes Ready and Reveal in Finder to this rail.
    var documentPhases: [String: PRReviewDocumentPhase] {
        guard let machineID, let selectedReviewID else { return [:] }
        return documentResources.phases(machineID: machineID, reviewID: selectedReviewID)
    }

    var documentCache: PRReviewDocumentCache { documentResources.cache }

    enum PRReviewDocumentPhase: Equatable {
        case idle
        case uploading
        case downloading
        case ready(URL)
        case failed(String)
    }

    struct PRReviewDocumentUpload: Equatable {
        enum Status: Equatable {
            case uploading
            case uploaded
            case failed(String)
        }

        var url: URL
        var status: Status
    }

    /// The connection and selection an asynchronous operation started under.
    ///
    /// `configure`, `reconnect`, and `invalidateConnection` bump `generation`,
    /// and `select` changes the review. Either makes a late success or error
    /// stale, so it must not publish state even when it names the review the
    /// window still shows.
    private struct PRReviewOperationScope: Equatable {
        let generation: Int
        let machineID: String?
        let reviewID: String?
    }

    init(
        documentCache: PRReviewDocumentCache = PRReviewDocumentCache(),
        documentResources: PRReviewDocumentResources? = nil
    ) {
        self.documentResources = documentResources ?? PRReviewDocumentResources(cache: documentCache)
    }

    /// A new host must discard every server-specific selection before a late response arrives.
    func configure(client: (any PRReviewClient)?, machineID: String?, demo: Bool) {
        generation &+= 1
        settleInterruptedProgress()
        releaseOutstandingDocumentLeases()
        self.client = client
        self.machineID = machineID
        isDemo = demo
        unconfigured = !demo && (client == nil || machineID == nil)
        reviews = []
        archivedReviews = []
        selectedReviewID = nil
        snapshot = nil
        diff = nil
        diffLoadError = nil
        diffLoadErrorIdentity = nil
        loadingDiffIdentity = nil
        completedDiffIdentity = nil
        selectedPath = nil
        hasLoaded = false
        unsupported = false
        error = nil
        capabilities = nil
        documentUploads = [:]
        contextImportError = nil

        if demo {
            reviews = PRReviewDemo.reviews()
            archivedReviews = PRReviewDemo.archivedReviews()
            select(PRReviewDemo.reviewID)
        }
    }

    func select(_ id: String?) {
        selectedReviewID = id
        snapshot = nil
        diff = nil
        diffLoadError = nil
        diffLoadErrorIdentity = nil
        loadingDiffIdentity = nil
        completedDiffIdentity = nil
        selectedPath = nil
        error = nil
    }

    /// Replaces the transport for the same machine and review without
    /// discarding the presentation this window already owns.
    ///
    /// A credential, URL, or host re-activation must not reset the open tab,
    /// filters, or selected file. Bumping the generation rejects every
    /// in-flight response from the previous client while the refresh reloads
    /// the same review, so the pinned window keeps its own local state.
    ///
    /// Operations that were in flight when the transport changed can no longer
    /// publish their completion, so their progress settles into a terminal,
    /// retryable state here instead of spinning forever. Nothing is resent; a
    /// following refresh reconciles uploads that did reach the server.
    func reconnect(client: (any PRReviewClient)?, machineID: String?, demo: Bool) {
        generation &+= 1
        self.client = client
        self.machineID = machineID
        isDemo = demo
        unconfigured = !demo && (client == nil || machineID == nil)
        isRefreshing = false
        loadingDiffIdentity = nil
        diffLoadError = nil
        diffLoadErrorIdentity = nil
        settleInterruptedProgress()
    }

    /// Invalidates every in-flight request and drops access to the configured
    /// client without touching this window's presentation.
    ///
    /// A host that becomes unavailable, or a window that stops, must not keep
    /// a usable transport: a late response from the old client can no longer
    /// install state, and a retained document window has nothing to retry
    /// through until the host returns and the window is re-activated.
    func invalidateConnection() {
        generation &+= 1
        client = nil
        isDemo = false
        unconfigured = true
        isRefreshing = false
        loadingDiffIdentity = nil
        settleInterruptedProgress()
        releaseOutstandingDocumentLeases()
    }

    var currentMachineID: String? { machineID }

    /// Captures an independent, host-pinned transport for a document window.
    ///
    /// A document window outlives this store: the main store can switch review
    /// hosts, and a pop-out session invalidates its store when it closes.
    /// Pinning the configured machine and client here keeps a later Try Again
    /// on the host the document was opened from instead of whichever host this
    /// store now points at.
    func documentTransport(for document: PRReviewDocument) -> PRReviewDocumentTransport? {
        guard let machineID, isDemo || client != nil else { return nil }
        return PRReviewDocumentTransport(
            machineID: machineID,
            reviewID: document.reviewID,
            isDemo: isDemo,
            client: client,
            resources: documentResources
        )
    }

    var selectedReview: PRReviewSummary? {
        (reviews + archivedReviews).first { $0.id == selectedReviewID }
    }

    /// Preparing work deserves prompt feedback, while settled reviews avoid needless traffic.
    var pollingInterval: Duration {
        guard let review = snapshot?.review ?? selectedReview else {
            return .seconds(30)
        }

        if review.status == .preparing || review.rankingState == .running || review.runningRuns > 0 {
            return .seconds(5)
        }

        return .seconds(30)
    }

    var orderedFiles: [PRReviewFile] {
        let files = snapshot?.files ?? []
        let ordered: [PRReviewFile]

        if viewMode == .github {
            ordered = files
        } else {
            ordered = files.sorted {
                ($0.guidedOrder ?? .max, $0.path) < ($1.guidedOrder ?? .max, $1.path)
            }
        }

        return ordered.filter(matchesFilters)
    }

    func nextFile() -> PRReviewFile? {
        guard let selectedPath,
              let index = orderedFiles.firstIndex(where: { $0.path == selectedPath }),
              index + 1 < orderedFiles.count
        else {
            return nil
        }

        return orderedFiles[index + 1]
    }

    func previousFile() -> PRReviewFile? {
        guard let selectedPath,
              let index = orderedFiles.firstIndex(where: { $0.path == selectedPath }),
              index > 0
        else {
            return nil
        }

        return orderedFiles[index - 1]
    }

    func refresh() async {
        let refreshGeneration = generation
        guard !unconfigured else {
            return
        }

        if isDemo {
            hasLoaded = true
            snapshot = PRReviewDemo.snapshot(for: selectedReviewID ?? PRReviewDemo.reviewID)
            error = nil
            return
        }

        guard let client else {
            return
        }

        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        do {
            let serverCapabilities = try await client.prReviewCapabilities()
            guard refreshGeneration == generation else {
                return
            }

            let activeReviews = try await client.prReviews(scope: "active")
            let archived = try await client.prReviews(scope: "archived")
            guard refreshGeneration == generation else {
                return
            }

            capabilities = serverCapabilities
            reviews = activeReviews
            archivedReviews = archived
            hasLoaded = true
            error = nil

            if let selectedReviewID {
                let value = try await client.prReview(id: selectedReviewID)
                guard refreshGeneration == generation else {
                    return
                }
                receive(value)
            }
        } catch {
            guard refreshGeneration == generation else {
                return
            }
            hasLoaded = true
            if case let APIError.server(status, _) = error, status == 404 || status == 501 {
                unsupported = true
                self.error = "This companion server needs PR Review support. Update the server to a version with pr-review-v1."
            } else if !HerdrCancellation.isCancellation(error) {
                self.error = error.localizedDescription
            }
        }
    }

    func refreshSelected() async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let value = try await client.prReview(id: selectedReviewID)
            guard isCurrentSelection(scope) else { return }
            receive(value)
            error = nil
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    var currentDiffRequestIdentity: PRReviewDiffRequestIdentity? {
        guard let selectedReviewID, let selectedPath else { return nil }
        return PRReviewDiffRequestIdentity(
            generation: generation,
            machineID: machineID,
            reviewID: selectedReviewID,
            path: selectedPath,
            baseSHA: (snapshot?.review ?? selectedReview)?.baseSHA ?? "",
            headSHA: (snapshot?.review ?? selectedReview)?.headSHA ?? ""
        )
    }

    var currentDiffLoadError: String? {
        guard diffLoadErrorIdentity == currentDiffRequestIdentity else { return nil }
        return diffLoadError
    }

    func loadDiff(for path: String?) async {
        guard let path,
              let selectedReviewID,
              let identity = currentDiffRequestIdentity,
              identity.path == path
        else { return }
        loadingDiffIdentity = identity
        if completedDiffIdentity == identity {
            completedDiffIdentity = nil
        }
        if diffLoadErrorIdentity == identity {
            diffLoadError = nil
            diffLoadErrorIdentity = nil
        }
        defer {
            if loadingDiffIdentity == identity {
                loadingDiffIdentity = nil
            }
        }
        if isDemo {
            guard currentDiffRequestIdentity == identity else { return }
            diff = PRReviewDemo.diff(for: selectedReviewID)
            completedDiffIdentity = identity
            return
        }
        guard let client else { return }
        do {
            let value = try await client.prReviewDiff(id: selectedReviewID, path: path)
            guard !Task.isCancelled,
                  currentDiffRequestIdentity == identity
            else { return }
            guard (value.reviewID.isEmpty || value.reviewID == identity.reviewID),
                  (identity.baseSHA.isEmpty || value.baseSHA == identity.baseSHA),
                  (identity.headSHA.isEmpty || value.headSHA == identity.headSHA)
            else {
                diffLoadError = "The companion returned a diff for a different review revision. Retry after the review refresh finishes."
                diffLoadErrorIdentity = identity
                completedDiffIdentity = identity
                return
            }
            diff = value
            completedDiffIdentity = identity
            diffLoadError = nil
            diffLoadErrorIdentity = nil
        } catch {
            guard currentDiffRequestIdentity == identity,
                  !Task.isCancelled,
                  !HerdrCancellation.isCancellation(error)
            else { return }
            diffLoadError = error.localizedDescription
            diffLoadErrorIdentity = identity
            completedDiffIdentity = identity
        }
    }

    /// Rejecting an older revision prevents polling from erasing a newer user action.
    func receive(_ value: PRReviewSnapshot) {
        guard selectedReviewID == nil || selectedReviewID == value.review.id else {
            return
        }
        guard selectedReview?.revision ?? 0 <= value.review.revision else {
            return
        }

        snapshot = value
        selectedReviewID = value.review.id
        if reviews.contains(where: { $0.id == value.review.id }) || archivedReviews.contains(where: { $0.id == value.review.id }) {
            replaceReview(value.review)
        } else if value.review.archivedAt == nil {
            reviews.insert(value.review, at: 0)
        } else {
            archivedReviews.insert(value.review, at: 0)
        }
        reconcileSettledUploads(with: value)
    }

    func setViewed(paths: [String], viewed: Bool) async {
        guard var snapshot else {
            return
        }

        for index in snapshot.files.indices where paths.contains(snapshot.files[index].path) {
            snapshot.files[index].viewed = viewed
        }
        self.snapshot = snapshot

        guard !isDemo,
              let selectedReviewID,
              let client
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let files = try await client.setPRReviewViewed(
                id: selectedReviewID,
                paths: paths,
                viewed: viewed,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope),
                  var current = self.snapshot,
                  current.review.id == scope.reviewID
            else {
                return
            }
            current.files = files
            self.snapshot = current
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func create(url: String, skillIDs: [String] = []) async {
        guard let client, !isDemo else {
            return
        }

        isCreating = true
        defer { isCreating = false }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let value = try await client.createPRReview(
                url: url,
                skillIDs: skillIDs,
                requestID: UUID().uuidString
            )
            guard isCurrentConnection(scope) else { return }
            receive(value)
            if !reviews.contains(where: { $0.id == value.review.id }) {
                reviews.insert(value.review, at: 0)
            }
            select(value.review.id)
        } catch {
            guard isCurrentConnection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func refreshReview() async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let value = try await client.refreshPRReview(
                id: selectedReviewID,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            receive(value)
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func archive(_ archived: Bool) async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let value = try await client.archivePRReview(
                id: selectedReviewID,
                archived: archived,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            receive(value)
            await refresh()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func runSkill(_ skillID: String) async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            _ = try await client.createPRReviewRun(
                id: selectedReviewID,
                skillID: skillID,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func finishRun(_ run: PRReviewRun, state: PRReviewRunState, note: String? = nil) async {
        guard let client, !isDemo else {
            return
        }

        let scope = operationScope(reviewID: run.reviewID)

        do {
            _ = try await client.finishPRReviewRun(
                reviewID: run.reviewID,
                runID: run.id,
                state: state,
                note: note,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func markSkill(_ skillID: String, state: String, note: String? = nil) async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            _ = try await client.markPRReviewSkill(
                reviewID: selectedReviewID,
                skillID: skillID,
                state: state,
                note: note,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func rank() async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            _ = try await client.rankPRReview(id: selectedReviewID, requestID: UUID().uuidString)
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func syncViewed() async {
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let files = try await client.syncPRReviewViewed(
                id: selectedReviewID,
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope),
                  var current = snapshot,
                  current.review.id == scope.reviewID
            else {
                return
            }
            current.files = files
            snapshot = current
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func runOutput(runID: String) async throws -> String {
        guard let reviewID = selectedReviewID else { return "" }
        if isDemo {
            return "Garden planner review output\n\nChecked catalog synchronization paths.\nNo blocking issues found."
        }
        guard let client else { return "" }
        return try await client.prReviewRunOutput(reviewID: reviewID, runID: runID, lines: 200)
    }

    func addSkill(
        id: String,
        title: String,
        kind: PRReviewSkillKind,
        promptTemplate: String,
        outputs: [String],
        description: String
    ) async {
        if isDemo {
            appendDemoSkill(
                id: id,
                title: title,
                kind: kind,
                promptTemplate: promptTemplate,
                outputs: outputs,
                description: description
            )
            return
        }
        guard let client else { return }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            _ = try await client.addPRReviewSkill(.init(
                id: id,
                title: title,
                kind: kind,
                promptTemplate: promptTemplate,
                commandTemplate: nil,
                outputs: outputs,
                description: description,
                requestID: UUID().uuidString
            ))
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func removeSkill(id: String) async {
        if isDemo {
            snapshot?.skills.removeAll { $0.id == id }
            return
        }
        guard let client else { return }

        let scope = operationScope(reviewID: selectedReviewID)

        do {
            _ = try await client.removePRReviewSkill(id: id, requestID: UUID().uuidString)
            guard isCurrentSelection(scope) else { return }
            await refreshSelected()
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
        }
    }

    func uploadDocuments(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        for url in urls {
            let reviewID = selectedReviewID
            let scope = operationScope(reviewID: reviewID)
            let uploadKey = documentUploadKey(reviewID: reviewID, url: url)
            documentUploads[uploadKey] = .init(url: url, status: .uploading)
            do {
                let document = try await uploadDocument(url: url)
                guard isCurrentConnection(scope) else { return }
                // The transfer row belongs to its own review, so it settles
                // even when the user has since selected another review. A
                // changed connection is settled by `settleInterruptedProgress`
                // and this stale completion must not overwrite it.
                documentUploads[uploadKey] = .init(url: url, status: .uploaded)
                guard isCurrentSelection(scope) else { return }
                appendDocument(document)
            } catch {
                guard isCurrentConnection(scope),
                      !HerdrCancellation.isCancellation(error)
                else {
                    return
                }
                let message = error.localizedDescription
                documentUploads[uploadKey] = .init(url: url, status: .failed(message))
                guard isCurrentSelection(scope) else { return }
                contextImportError = message
            }
        }
    }

    func retryUpload(url: URL) {
        Task { await uploadDocuments(urls: [url]) }
    }

    func addLink(url: String, title: String) async {
        guard let validated = Self.webURL(from: url) else {
            contextImportError = "Enter a valid http or https link."
            return
        }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = resolvedTitle.isEmpty ? validated.absoluteString : resolvedTitle

        if isDemo {
            appendDocument(Self.demoDocument(
                id: "prdoc-link-\(UUID().uuidString)",
                reviewID: selectedReviewID ?? PRReviewDemo.reviewID,
                kind: .link,
                title: displayTitle,
                filename: "",
                url: validated.absoluteString,
                byteSize: 0,
                origin: "user",
                downloadable: false
            ))
            return
        }
        guard let selectedReviewID, let client else { return }
        let scope = operationScope(reviewID: selectedReviewID)

        do {
            let document = try await client.addPRReviewDocument(
                id: selectedReviewID,
                payload: .link(url: validated.absoluteString, title: displayTitle),
                requestID: UUID().uuidString
            )
            guard isCurrentSelection(scope) else { return }
            appendDocument(document)
        } catch {
            guard isCurrentSelection(scope),
                  !HerdrCancellation.isCancellation(error)
            else {
                return
            }
            record(error)
            contextImportError = error.localizedDescription
        }
    }

    func localURL(for document: PRReviewDocument) async throws -> URL {
        guard let machineID else { throw APIError.invalidResponse }
        let reviewID = document.reviewID
        let scope = operationScope(reviewID: reviewID)
        let resourceScope = documentResources.scope(
            machineID: machineID,
            reviewID: reviewID,
            documentID: document.id
        )
        heldDocumentScopes.insert(resourceScope)
        documentResources.setPhase(.downloading, for: resourceScope)
        let destination = try documentCache.prepareDestinationURL(
            machineID: machineID,
            reviewID: reviewID,
            document: document
        )

        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                if isDemo {
                    try Self.demoDocumentData(for: document).write(to: destination, options: .atomic)
                } else {
                    guard let client else { throw APIError.invalidResponse }
                    try await client.downloadPRReviewDocument(
                        reviewID: reviewID,
                        documentID: document.id,
                        expectedByteSize: document.byteSize,
                        to: destination
                    )
                }
            }
            guard isCurrentConnection(scope) else { throw CancellationError() }
            try documentCache.markAccessed(destination)
            documentResources.setPhase(.ready(destination), for: resourceScope)
            // The freshly installed destination is protected even before the
            // presenting window takes its lease, so a second store's cleanup
            // at the retention limit cannot evict the file just downloaded.
            try? documentResources.cleanup(additionallyProtecting: [destination])
            return destination
        } catch {
            guard isCurrentConnection(scope) else { throw CancellationError() }
            documentResources.setPhase(.failed(error.localizedDescription), for: resourceScope)
            throw error
        }
    }

    /// Takes a window-lifetime cache protection for a displayed document.
    /// The lease keeps retention cleanup from evicting the file while the
    /// window shows it; the shared phase still publishes Ready and Reveal to
    /// every rail reading this review.
    func acquireDocumentLease(for url: URL) -> PRReviewDocumentLease {
        documentResources.acquireLease(for: url)
        let lease = PRReviewDocumentLease(url: url) { [documentResources] in
            documentResources.releaseLease(for: url)
        }
        documentLeases[ObjectIdentifier(lease)] = lease
        return lease
    }

    func releaseDocumentLease(_ lease: PRReviewDocumentLease) {
        lease.release()
        documentLeases[ObjectIdentifier(lease)] = nil
    }

    /// Releases every protection this store still owns, e.g. when its window
    /// closes. Double releases are already no-ops.
    func releaseOutstandingDocumentLeases() {
        let leases = documentLeases.values
        documentLeases.removeAll()
        for lease in leases { lease.release() }
    }

    func scroll(to path: String, line: Int, side: PRReviewSide) {
        selectedPath = path
        scrollRequest = (path, line, side, (scrollRequest?.token ?? 0) + 1)
    }

    private func uploadDocument(url: URL) async throws -> PRReviewDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AttachmentPolicyError.unreadableFileSize(filename: url.lastPathComponent)
        }
        try AttachmentPolicy.validateFile(
            named: url.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0)
        )
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        if isDemo {
            return Self.demoDocument(
                id: "prdoc-upload-\(UUID().uuidString)",
                reviewID: selectedReviewID ?? PRReviewDemo.reviewID,
                kind: Self.documentKind(for: url),
                title: url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                url: nil,
                byteSize: Int64(data.count),
                origin: "user",
                downloadable: true
            )
        }
        guard let selectedReviewID, let client else { throw APIError.invalidResponse }
        return try await client.addPRReviewDocument(
            id: selectedReviewID,
            payload: .upload(
                filename: url.lastPathComponent,
                contentType: mediaType,
                dataBase64: data.base64EncodedString(),
                title: url.deletingPathExtension().lastPathComponent
            ),
            requestID: UUID().uuidString
        )
    }

    private func appendDocument(_ document: PRReviewDocument) {
        guard var snapshot, snapshot.review.id == document.reviewID else { return }
        snapshot.documents.removeAll { $0.id == document.id }
        snapshot.documents.append(document)
        snapshot.review.documentCount = snapshot.documents.count
        self.snapshot = snapshot
    }

    private func appendDemoSkill(
        id: String,
        title: String,
        kind: PRReviewSkillKind,
        promptTemplate: String,
        outputs: [String],
        description: String
    ) {
        guard var snapshot else { return }
        snapshot.skills.append(.init(
            id: id,
            title: title,
            kind: kind,
            runner: "agent",
            promptTemplate: promptTemplate,
            commandTemplate: "",
            outputs: outputs,
            description: description,
            builtin: false,
            enabled: true,
            state: "not_run",
            mark: nil,
            runCount: 0,
            lastRunAt: nil,
            running: false
        ))
        self.snapshot = snapshot
    }

    private static func webURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { return nil }
        return url
    }

    private static func documentKind(for url: URL) -> PRReviewDocumentKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "html", "htm": .html
        case "mp3", "m4a", "wav": .audio
        case "mov", "mp4", "m4v", "webm": .video
        default: .file
        }
    }

    private static func demoDocument(
        id: String,
        reviewID: String,
        kind: PRReviewDocumentKind,
        title: String,
        filename: String,
        url: String?,
        byteSize: Int64,
        origin: String,
        downloadable: Bool
    ) -> PRReviewDocument {
        .init(
            id: id,
            reviewID: reviewID,
            runID: nil,
            kind: kind,
            title: title,
            mediaType: "application/octet-stream",
            filename: filename,
            url: url,
            byteSize: byteSize,
            contentHash: UUID().uuidString,
            origin: origin,
            originPath: nil,
            createdAt: ISO8601DateFormatter().string(from: .now),
            downloadable: downloadable
        )
    }

    private static func demoDocumentData(for document: PRReviewDocument) -> Data {
        switch document.kind {
        case .markdown:
            Data("# \(document.title)\n\nFictional garden planner review notes.\n".utf8)
        case .html:
            Data("<html><body><h1>\(document.title)</h1><p>Fictional garden planner report.</p></body></html>".utf8)
        default:
            Data("Fictional PR review document: \(document.title)".utf8)
        }
    }

    private func matchesFilters(_ file: PRReviewFile) -> Bool {
        let matchesImpact: Bool
        switch impactFilter {
        case .all:
            matchesImpact = true
        case .unranked:
            matchesImpact = file.impact == nil || file.impact == .unknown
        case .high, .medium, .low:
            matchesImpact = file.impact?.rawValue == impactFilter.rawValue
        }

        return matchesImpact
            && (!hideViewed || !file.viewed)
            && (search.isEmpty || file.path.localizedCaseInsensitiveContains(search))
    }

    private func replaceReview(_ review: PRReviewSummary) {
        if let index = reviews.firstIndex(where: { $0.id == review.id }) {
            reviews[index] = review
        }
        if let index = archivedReviews.firstIndex(where: { $0.id == review.id }) {
            archivedReviews[index] = review
        }
    }

    private func record(_ failure: Error) {
        error = failure.localizedDescription
    }

    /// A reconnect or host removal makes every in-flight operation's completion
    /// stale. Upload rows and download rows must not keep spinning with no
    /// Retry, so they settle into a terminal, retryable state here. The
    /// operations themselves are never resent; the next refresh reconciles
    /// uploads that did reach the server before the transport changed.
    private func settleInterruptedProgress() {
        let uploadMessage = "The connection changed before this upload finished. Retry to upload it again."
        let downloadMessage = "This download was interrupted. Open the document to try again."
        let interruptedUploads = documentUploads.filter { entry in
            if case .uploading = entry.value.status { return true }
            return false
        }
        for (key, upload) in interruptedUploads {
            documentUploads[key] = .init(url: upload.url, status: .failed(uploadMessage))
        }
        for scope in heldDocumentScopes where documentResources.phase(for: scope) == .downloading {
            documentResources.setPhase(.failed(downloadMessage), for: scope)
        }
    }

    /// A refreshed snapshot is the reconciliation point for uploads that were
    /// interrupted by a connection change: if this review's document list
    /// contains the upload, the server received it after all, so the row stops
    /// offering Retry.
    private func reconcileSettledUploads(with value: PRReviewSnapshot) {
        let reviewPrefix = "\(value.review.id)|"
        let settledUploads = documentUploads.filter { entry in
            guard entry.key.hasPrefix(reviewPrefix), case .failed = entry.value.status else { return false }
            return true
        }
        for (key, upload) in settledUploads {
            let filename = upload.url.lastPathComponent
            guard !filename.isEmpty,
                  value.documents.contains(where: {
                      $0.filename == filename && $0.origin.lowercased() == "user"
                  })
            else { continue }
            documentUploads[key] = .init(url: upload.url, status: .uploaded)
        }
    }

    private func operationScope(reviewID: String?) -> PRReviewOperationScope {
        PRReviewOperationScope(generation: generation, machineID: machineID, reviewID: reviewID)
    }

    /// True while the operation still belongs to this store's configured
    /// connection. A reconnect or invalidation makes every earlier scope stale.
    private func isCurrentConnection(_ scope: PRReviewOperationScope) -> Bool {
        generation == scope.generation && machineID == scope.machineID
    }

    /// True while the operation still belongs to the configured connection and
    /// the review it started for is still selected.
    private func isCurrentSelection(_ scope: PRReviewOperationScope) -> Bool {
        isCurrentConnection(scope) && selectedReviewID == scope.reviewID
    }

    private func documentUploadKey(reviewID: String?, url: URL) -> String {
        "\(reviewID ?? "unselected")|\(url.path)"
    }
}
