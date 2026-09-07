import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Result document availability", .serialized)
@MainActor
struct AgentResultArtifactAvailabilityTests {
    @Test("Missing documents report unavailable, not a connection failure", arguments: [404, 410])
    func missingDocument(status: Int) async throws {
        let script = ArtifactAvailabilityProbeScript(statuses: [status, status])
        let checker = AgentResultArtifactLinkChecker { try await script.response(for: $0) }
        do {
            try await checker.check(URL(string: "https://example.test/report")!)
            Issue.record("Expected missing-document failure")
        } catch let error as AgentResultArtifactAvailabilityError {
            #expect(error == .notFound)
            #expect(error.alertTitle == "Document unavailable")
            #expect(error.allowsBrowserFallback)
        }
        let requests = await script.requests()
        #expect(requests.map(\.httpMethod) == (status == 404 ? ["HEAD", "GET"] : ["HEAD"]))
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == (status == 404 ? "bytes=0-0" : nil))
    }

    @Test("Authentication and unsupported HEAD defer to a working browser", arguments: [[401], [403], [404, 200], [405, 200], [404, 401]])
    func authenticatedDocumentsRemainOpenable(statuses: [Int]) async throws {
        let script = ArtifactAvailabilityProbeScript(statuses: statuses)
        let checker = AgentResultArtifactLinkChecker { try await script.response(for: $0) }
        try await checker.check(URL(string: "https://example.test/private-report")!)
    }

    @Test("Temporary HTTP errors remain retryable", arguments: [429, 500, 503])
    func serverFailureIsNotMissing(status: Int) async throws {
        let script = ArtifactAvailabilityProbeScript(statuses: [status])
        let checker = AgentResultArtifactLinkChecker { try await script.response(for: $0) }
        do {
            try await checker.check(URL(string: "https://example.test/report")!)
            Issue.record("Expected temporary failure")
        } catch let error as AgentResultArtifactAvailabilityError {
            #expect(error == .serverUnavailable)
            #expect(!error.allowsBrowserFallback)
        }
    }

    @Test("Offline, permission, timeout and missing-file failures stay distinct")
    func errorClassification() {
        #expect(AgentResultArtifactAvailabilityError.normalized(URLError(.notConnectedToInternet)) as? AgentResultArtifactAvailabilityError == .offline)
        #expect(AgentResultArtifactAvailabilityError.normalized(URLError(.timedOut)) as? AgentResultArtifactAvailabilityError == .timedOut)
        #expect(AgentResultArtifactAvailabilityError.normalized(CocoaError(.fileReadNoPermission)) as? AgentResultArtifactAvailabilityError == .accessDenied)
        #expect(AgentResultArtifactAvailabilityError.normalized(CocoaError(.fileReadNoSuchFile)) as? AgentResultArtifactAvailabilityError == .notFound)
        #expect(AgentResultArtifactAvailabilityError.normalized(APIError.server(status: 404, message: "")) as? AgentResultArtifactAvailabilityError == .notFound)
        #expect(AgentResultArtifactAvailabilityError.normalized(APIError.noActiveConnection(machineID: "work")) as? AgentResultArtifactAvailabilityError == .offline)
        #expect(AgentResultArtifactAvailabilityError.normalized(CancellationError()) is CancellationError)
    }

    @Test("Unavailable link is retryable and browser fallback skips the checker")
    func openerAvailabilityAndBrowserFallback() async throws {
        let suiteName = "AgentResultArtifactAvailabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        var opens = 0
        var checks = 0
        let opener = AgentResultArtifactOpener(cache: AgentResultArtifactCache(rootURL: root), ledger: ledger,
            openURL: { _ in opens += 1; return true },
            checkLinkAvailability: { _ in checks += 1; throw AgentResultArtifactAvailabilityError.notFound })
        let artifact = AgentResultArtifact(id: "missing", originType: .pane, originID: "p1", kind: .link,
                                          title: "Report", createdAt: "", url: URL(string: "https://example.test/report"))
            .stamped(machineID: "work")
        do {
            try await opener.open(artifact)
            Issue.record("Expected missing link")
        } catch let error as AgentResultArtifactAvailabilityError { #expect(error == .notFound) }
        #expect(opens == 0)
        #expect(!ledger.contains(artifact.id))
        try await opener.open(artifact, allowUnverifiedLink: true)
        #expect(checks == 1)
        #expect(opens == 1)
        #expect(ledger.contains(artifact.id))
    }

    @Test("Removed file payload leaves the artifact unopened")
    func removedFileDownload() async throws {
        let suiteName = "AgentResultArtifactAvailabilityTests.file.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        var opens = 0
        let opener = AgentResultArtifactOpener(cache: AgentResultArtifactCache(rootURL: root), ledger: ledger,
                                               openURL: { _ in opens += 1; return true })
        let artifact = AgentResultArtifact(id: "missing", originType: .pane, originID: "p1", kind: .file,
                                          title: "Report", filename: "report.txt", byteSize: 5, createdAt: "",
                                          downloadPath: "/api/v1/result-artifacts/missing/content").stamped(machineID: "work")
        do {
            try await opener.open(artifact, downloadFile: { _ in throw APIError.server(status: 410, message: "Gone") })
            Issue.record("Expected missing file")
        } catch let error as AgentResultArtifactAvailabilityError { #expect(error == .notFound) }
        #expect(opens == 0)
        #expect(!ledger.contains(artifact.id))
    }

    @Test("Model opens a cached document while its source is offline and reports an uncached document as offline")
    func offlineCachedDocumentModel() async throws {
        let suiteName = "AgentResultArtifactAvailabilityTests.offline-cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AgentResultArtifactCache(rootURL: root)
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        var openedURLs: [URL] = []
        let opener = AgentResultArtifactOpener(cache: cache, ledger: ledger,
                                               openURL: { openedURLs.append($0); return true })
        let model = HerdrAppModel(arguments: ["HerdrTests"], userDefaults: defaults, resultArtifactOpener: opener)
        func artifact(id: String) -> AgentResultArtifact {
            AgentResultArtifact(id: id, originType: .pane, originID: "p1", kind: .file,
                                title: "Report", filename: "report.txt", byteSize: 5, createdAt: "",
                                downloadPath: "/api/v1/result-artifacts/\(id)/content")
                .stamped(machineID: "missing-source-machine")
        }
        let cached = artifact(id: "cached")
        let destination = try cache.prepareDestinationURL(for: cached)
        try Data("hello".utf8).write(to: destination)
        #expect(!model.canControl(machineID: cached.machineID))

        let cachedFailure = await model.openResultArtifact(cached)

        #expect(cachedFailure == nil)
        #expect(openedURLs == [destination])
        #expect(model.resultArtifactPhase(id: cached.id) == .opened)
        #expect(ledger.contains(cached.id))

        let uncached = artifact(id: "uncached")
        let unavailable = await model.openResultArtifact(uncached)
        #expect(unavailable?.title == AgentResultArtifactAvailabilityError.offline.alertTitle)
        #expect(unavailable?.allowsBrowserFallback == false)
        #expect(openedURLs == [destination])
        #expect(!ledger.contains(uncached.id))
    }
}

private actor ArtifactAvailabilityProbeScript {
    private var statuses: [Int]
    private var recorded: [URLRequest] = []

    init(statuses: [Int]) { self.statuses = statuses }

    func response(for request: URLRequest) throws -> HTTPURLResponse {
        recorded.append(request)
        return try #require(HTTPURLResponse(url: request.url!, statusCode: statuses.removeFirst(), httpVersion: nil, headerFields: nil))
    }

    func requests() -> [URLRequest] { recorded }
}
