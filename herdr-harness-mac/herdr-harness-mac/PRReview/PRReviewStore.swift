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
    private let documentCache: PRReviewDocumentCache

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
    var documentPhases: [String: PRReviewDocumentPhase] = [:]
    var documentUploads: [String: PRReviewDocumentUpload] = [:]
    var protectedDocumentURLs: Set<URL> = []
    var contextImportError: String?
    var unconfigured = false

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

    init(documentCache: PRReviewDocumentCache = PRReviewDocumentCache()) {
        self.documentCache = documentCache
    }

    /// A new host must discard every server-specific selection before a late response arrives.
    func configure(client: (any PRReviewClient)?, machineID: String?, demo: Bool) {
        generation &+= 1
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
        documentPhases = [:]
        documentUploads = [:]
        protectedDocumentURLs = []
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

    var currentMachineID: String? { machineID }

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
            snapshot = PRReviewDemo.snapshot()
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
        let refreshGeneration = generation
        guard let selectedReviewID,
              let client,
              !isDemo
        else {
            return
        }

        do {
            let value = try await client.prReview(id: selectedReviewID)
            guard refreshGeneration == generation else {
                return
            }
            receive(value)
            error = nil
        } catch {
            guard refreshGeneration == generation else {
                return
            }
            if !HerdrCancellation.isCancellation(error) { record(error) }
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
            diff = PRReviewDemo.diff()
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

        do {
            let files = try await client.setPRReviewViewed(
                id: selectedReviewID,
                paths: paths,
                viewed: viewed,
                requestID: UUID().uuidString
            )
            guard self.selectedReviewID == selectedReviewID,
                  var current = self.snapshot
            else {
                return
            }
            current.files = files
            self.snapshot = current
        } catch {
            record(error)
        }
    }

    func create(url: String, skillIDs: [String] = []) async {
        guard let client, !isDemo else {
            return
        }

        isCreating = true
        defer { isCreating = false }

        do {
            let value = try await client.createPRReview(
                url: url,
                skillIDs: skillIDs,
                requestID: UUID().uuidString
            )
            receive(value)
            if !reviews.contains(where: { $0.id == value.review.id }) {
                reviews.insert(value.review, at: 0)
            }
            select(value.review.id)
        } catch {
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

        do {
            let value = try await client.refreshPRReview(
                id: selectedReviewID,
                requestID: UUID().uuidString
            )
            receive(value)
        } catch {
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

        do {
            let value = try await client.archivePRReview(
                id: selectedReviewID,
                archived: archived,
                requestID: UUID().uuidString
            )
            receive(value)
            await refresh()
        } catch {
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

        do {
            _ = try await client.createPRReviewRun(
                id: selectedReviewID,
                skillID: skillID,
                requestID: UUID().uuidString
            )
            await refreshSelected()
        } catch {
            record(error)
        }
    }

    func finishRun(_ run: PRReviewRun, state: PRReviewRunState, note: String? = nil) async {
        guard let client, !isDemo else {
            return
        }

        do {
            _ = try await client.finishPRReviewRun(
                reviewID: run.reviewID,
                runID: run.id,
                state: state,
                note: note,
                requestID: UUID().uuidString
            )
            await refreshSelected()
        } catch {
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

        do {
            _ = try await client.markPRReviewSkill(
                reviewID: selectedReviewID,
                skillID: skillID,
                state: state,
                note: note,
                requestID: UUID().uuidString
            )
            await refreshSelected()
        } catch {
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

        do {
            _ = try await client.rankPRReview(id: selectedReviewID, requestID: UUID().uuidString)
            await refreshSelected()
        } catch {
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

        do {
            snapshot?.files = try await client.syncPRReviewViewed(
                id: selectedReviewID,
                requestID: UUID().uuidString
            )
        } catch {
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
            await refreshSelected()
        } catch {
            record(error)
        }
    }

    func removeSkill(id: String) async {
        if isDemo {
            snapshot?.skills.removeAll { $0.id == id }
            return
        }
        guard let client else { return }

        do {
            _ = try await client.removePRReviewSkill(id: id, requestID: UUID().uuidString)
            await refreshSelected()
        } catch {
            record(error)
        }
    }

    func uploadDocuments(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        for url in urls {
            let reviewID = selectedReviewID
            let uploadKey = documentUploadKey(reviewID: reviewID, url: url)
            documentUploads[uploadKey] = .init(url: url, status: .uploading)
            do {
                let document = try await uploadDocument(url: url)
                appendDocument(document)
                documentUploads[uploadKey] = .init(url: url, status: .uploaded)
            } catch {
                let message = error.localizedDescription
                documentUploads[uploadKey] = .init(url: url, status: .failed(message))
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

        do {
            let document = try await client.addPRReviewDocument(
                id: selectedReviewID,
                payload: .link(url: validated.absoluteString, title: displayTitle),
                requestID: UUID().uuidString
            )
            appendDocument(document)
        } catch {
            record(error)
            contextImportError = error.localizedDescription
        }
    }

    func localURL(for document: PRReviewDocument) async throws -> URL {
        guard let machineID else { throw APIError.invalidResponse }
        let reviewID = document.reviewID
        documentPhases[document.id] = .downloading
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
            try documentCache.markAccessed(destination)
            documentPhases[document.id] = .ready(destination)
            try? documentCache.cleanup(protecting: protectedDocumentURLs)
            return destination
        } catch {
            documentPhases[document.id] = .failed(error.localizedDescription)
            throw error
        }
    }

    func protectDocumentURL(_ url: URL) {
        protectedDocumentURLs.insert(url.standardizedFileURL)
    }

    func unprotectDocumentURL(_ url: URL) {
        protectedDocumentURLs.remove(url.standardizedFileURL)
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

    private func documentUploadKey(reviewID: String?, url: URL) -> String {
        "\(reviewID ?? "unselected")|\(url.path)"
    }
}
