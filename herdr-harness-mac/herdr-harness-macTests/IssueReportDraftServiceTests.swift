import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Issue report draft service", .serialized)
@MainActor
struct IssueReportDraftServiceTests {
    @Test("Availability reflects only the advertised drafting profile")
    func availabilityReflectsProfile() async {
        let spy = DraftTransportSpy()
        let service = IssueReportDraftService(transport: spy.transport)

        let available = await service.availability(for: "machine-1")
        #expect(available == .available)

        spy.capabilityProfiles = ["pane-retirement-v1", "smart-rename-v1"]
        let unsupported = await service.availability(for: "machine-1")
        #expect(unsupported == .unsupportedCompanion)

        spy.capabilityError = APIError.server(status: 404, message: "no route")
        let unreachable = await service.availability(for: "machine-1")
        if case .unavailable = unreachable {
            // Expected.
        } else {
            Issue.record("Expected an unavailable companion result")
        }

        let missing = await service.availability(for: "")
        if case .unavailable = missing {
            // Expected.
        } else {
            Issue.record("Expected a missing-companion result")
        }
    }

    @Test("One drafting ask preflights, starts once, polls, and parses")
    func happyPath() async throws {
        let spy = DraftTransportSpy()
        let running = Self.makeRun(status: .running)
        let completed = Self.makeRun(status: .completed, response: ###"{"title":"Crash on launch","body":"## Steps\n1. Open"}"###)
        spy.startRun = running
        spy.fetchResponses = [running, completed]
        let service = IssueReportDraftService(transport: spy.transport, pollInterval: .milliseconds(1))

        let output = try await service.draft(kind: .bug, text: "it crashes when I open two windows", machineID: "machine-1")

        #expect(output == IssueReportDraftOutput(title: "Crash on launch", body: "## Steps\n1. Open"))
        #expect(spy.capabilityCalls == ["machine-1"])
        #expect(spy.startCalls.count == 1)
        #expect(spy.startCalls.first?.machineID == "machine-1")
        #expect(spy.startCalls.first?.request == IssueReportDraftRequest(kind: .bug, text: "it crashes when I open two windows"))
        #expect(spy.startCalls.first?.request.profile == IssueReportDraftProfile.identifier)
        #expect(spy.fetchCalls == ["run-1", "run-1"])
        #expect(spy.cancelCalls.isEmpty)
    }

    @Test("Blank or over-limit source is refused before any network call")
    func validatesSourceLocally() async {
        let spy = DraftTransportSpy()
        let service = IssueReportDraftService(transport: spy.transport)

        do {
            _ = try await service.draft(kind: .bug, text: "  \n ", machineID: "machine-1")
            Issue.record("Expected an empty source error")
        } catch {
            #expect(error as? IssueReportDraftError == .emptySource)
        }
        do {
            _ = try await service.draft(kind: .bug, text: String(repeating: "x", count: 20_001), machineID: "machine-1")
            Issue.record("Expected an over-limit source error")
        } catch {
            #expect(error as? IssueReportDraftError == .sourceTooLong(maximum: 20_000))
        }
        do {
            _ = try await service.draft(kind: .bug, text: "bell\u{0007}", machineID: "machine-1")
            Issue.record("Expected a control-character source error")
        } catch {
            #expect(error as? IssueReportDraftError == .sourceHasControlCharacters)
        }
        #expect(spy.capabilityCalls.isEmpty)
        #expect(spy.startCalls.isEmpty)
    }

    @Test("An older companion is refused before any start request")
    func oldCompanionIsRefused() async {
        let spy = DraftTransportSpy()
        spy.capabilityProfiles = ["pane-retirement-v1", "smart-rename-v1"]
        let service = IssueReportDraftService(transport: spy.transport)

        do {
            _ = try await service.draft(kind: .bug, text: "plain request", machineID: "machine-1")
            Issue.record("Expected an unsupported companion error")
        } catch {
            #expect(error as? IssueReportDraftError == .unsupportedCompanion)
        }
        #expect(spy.capabilityCalls == ["machine-1"])
        #expect(spy.startCalls.isEmpty)
    }

    @Test("Terminal failures, empty responses, and malformed output never become a result")
    func terminalFailures() async {
        let spy = DraftTransportSpy()
        let service = IssueReportDraftService(transport: spy.transport, pollInterval: .milliseconds(1))

        spy.startRun = Self.makeRun(status: .failed, error: "Pi provider is not configured")
        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected a run failure")
        } catch {
            #expect(error as? IssueReportDraftError == .runFailed("Pi provider is not configured"))
        }

        spy.startRun = Self.makeRun(status: .cancelled)
        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected a cancelled run")
        } catch {
            #expect(error as? IssueReportDraftError == .cancelled)
        }

        spy.startRun = Self.makeRun(status: .completed, response: nil)
        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected an empty output")
        } catch {
            #expect(error as? IssueReportDraftError == .emptyOutput)
        }

        spy.startRun = Self.makeRun(status: .completed, response: "not json")
        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected invalid output")
        } catch {
            #expect(error as? IssueReportDraftError == .invalidOutput(.notAnObject))
        }
        #expect(spy.startCalls.count == 4)
        #expect(spy.cancelCalls.isEmpty)
    }

    @Test("A poll failure ends the request instead of retrying the ask")
    func pollFailureDoesNotRetry() async {
        let spy = DraftTransportSpy()
        spy.startRun = Self.makeRun(status: .running)
        spy.fetchError = APIError.server(status: 500, message: "poll exploded")
        let service = IssueReportDraftService(transport: spy.transport, pollInterval: .milliseconds(1))

        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected a run failure")
        } catch {
            #expect(error as? IssueReportDraftError == .runFailed("poll exploded"))
        }
        #expect(spy.startCalls.count == 1)
        #expect(spy.fetchCalls == ["run-1"])
        // An abandoned polling failure still best-effort cancels the remote run.
        await Self.waitUntil("remote cancel") { spy.cancelCalls == ["run-1"] }
        #expect(spy.cancelCalls == ["run-1"])
    }

    @Test("A run that outlives the deadline is cancelled and fails")
    func timeoutCancelsRun() async {
        let spy = DraftTransportSpy()
        spy.startRun = Self.makeRun(status: .running)
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(30)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "slow request", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        #expect(spy.startCalls.count == 1)
        await Self.waitUntil("remote cancel") { spy.cancelCalls == ["run-1"] }
        #expect(spy.cancelCalls == ["run-1"])
    }

    @Test("A delayed preflight is refused at the shared deadline before any start")
    func delayedPreflightTimesOut() async {
        let spy = DraftTransportSpy()
        spy.capabilityDelay = .milliseconds(300)
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(30)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "slow preflight", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        #expect(spy.capabilityCalls == ["machine-1"])
        #expect(spy.startCalls.isEmpty)
        #expect(spy.fetchCalls.isEmpty)
        #expect(spy.cancelCalls.isEmpty)
    }

    @Test("A delayed start is refused at the shared deadline")
    func delayedStartTimesOut() async {
        let spy = DraftTransportSpy()
        spy.startDelay = .milliseconds(300)
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(30)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "slow start", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        #expect(spy.startCalls.count == 1)
        #expect(spy.fetchCalls.isEmpty)
        #expect(spy.cancelCalls.isEmpty)
    }

    @Test("A terminal fetch after the deadline is rejected and the run is cancelled")
    func lateTerminalFetchIsRejected() async {
        let spy = DraftTransportSpy()
        spy.startRun = Self.makeRun(status: .running)
        spy.fetchResponses = [Self.makeRun(status: .running), Self.makeRun(status: .completed, response: #"{"title":"Late","body":"Late"}"#)]
        spy.fetchDelays = [.milliseconds(1), .milliseconds(300)]
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(40)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "slow fetch", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        #expect(spy.fetchCalls == ["run-1", "run-1"])
        await Self.waitUntil("remote cancel") { spy.cancelCalls == ["run-1"] }
        #expect(spy.cancelCalls == ["run-1"])
    }

    @Test("The cleanup cancel cannot extend the busy state when the transport ignores cancellation")
    func cleanupIsFireAndForget() async {
        let spy = DraftTransportSpy()
        spy.startRun = Self.makeRun(status: .running)
        spy.cancelDelay = .seconds(30)
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(30)
        )

        let start = ContinuousClock().now
        do {
            _ = try await service.draft(kind: .bug, text: "slow request", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        #expect(start.duration(to: ContinuousClock().now) < .milliseconds(500))
        await Self.waitUntil("remote cancel") { spy.cancelCalls == ["run-1"] }
        #expect(spy.cancelCalls == ["run-1"])
    }

    @Test("Cancelling the caller cancels the remote run exactly once")
    func callerCancellationCancelsRun() async throws {
        let spy = DraftTransportSpy()
        spy.startRun = Self.makeRun(status: .running)
        let service = IssueReportDraftService(
            transport: spy.transport,
            pollInterval: .milliseconds(1),
            deadline: .seconds(5)
        )

        let task = Task { try await service.draft(kind: .bug, text: "cancel me", machineID: "machine-1") }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result

        guard case let .failure(error) = result else {
            Issue.record("Expected the draft to fail with cancellation")
            return
        }
        #expect(error as? IssueReportDraftError == .cancelled)
        #expect(spy.startCalls.count == 1)
        await Self.waitUntil("remote cancel") { spy.cancelCalls == ["run-1"] }
        #expect(spy.cancelCalls == ["run-1"])
    }

    @Test("The live HTTP transport sends the restricted body and maps run errors")
    func liveTransportWire() async throws {
        let envelope = Self.runEnvelope(status: "completed", response: #"{"title":"Live title","body":"Live body"}"#)
        IssueReportDraftStubURLProtocol.reset(replies: [
            "GET /api/v1/agent-runs/capabilities": .init(
                status: 200,
                body: #"{"ok":true,"profiles":["issue-report-draft-v1"]}"#
            ),
            "POST /api/v1/agent-runs": .init(status: 202, body: envelope),
        ])
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let service = IssueReportDraftService.live(configuration: configuration, session: Self.stubSession())

        let output = try await service.draft(kind: .feature, text: "make the window quiet", machineID: "machine-1")

        #expect(output == IssueReportDraftOutput(title: "Live title", body: "Live body"))
        let requests = IssueReportDraftStubURLProtocol.recordedRequests()
        #expect(requests.map(\.path) == ["/api/v1/agent-runs/capabilities", "/api/v1/agent-runs"])
        let start = try #require(requests.last)
        #expect(start.method == "POST")
        #expect(start.contentType == "application/json")
        #expect(start.authorization == "Bearer test")
        #expect(start.timeout == 90)
        let body = try #require(JSONSerialization.jsonObject(with: start.body) as? [String: Any])
        #expect(Set(body.keys) == ["profile", "kind", "text"])
        #expect(body["profile"] as? String == IssueReportDraftProfile.identifier)
        #expect(body["kind"] as? String == "feature")
        #expect(body["text"] as? String == "make the window quiet")
    }

    @Test("The live transport refuses an older companion before sending a draft")
    func liveOldCompanion() async throws {
        IssueReportDraftStubURLProtocol.reset(replies: [
            "GET /api/v1/agent-runs/capabilities": .init(
                status: 200,
                body: #"{"ok":true,"profiles":["smart-rename-v1","hud-chat-v1"]}"#
            ),
        ])
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let service = IssueReportDraftService.live(configuration: configuration, session: Self.stubSession())

        do {
            _ = try await service.draft(kind: .bug, text: "request", machineID: "machine-1")
            Issue.record("Expected an unsupported companion error")
        } catch {
            #expect(error as? IssueReportDraftError == .unsupportedCompanion)
        }
        #expect(IssueReportDraftStubURLProtocol.recordedRequests().map(\.path) == ["/api/v1/agent-runs/capabilities"])
    }

    @Test("The live transport fetches and cancels one run")
    func liveFetchAndCancel() async throws {
        let envelope = Self.runEnvelope(status: "running", id: "agr_test")
        IssueReportDraftStubURLProtocol.reset(replies: [
            "GET /api/v1/agent-runs/agr_test": .init(status: 200, body: envelope),
            "POST /api/v1/agent-runs/agr_test/cancel": .init(status: 200, body: envelope),
        ])
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let http = IssueReportDraftHTTPClient(configuration: configuration, session: Self.stubSession())

        let fetched = try await http.fetch(runID: "agr_test")
        #expect(fetched.status == .running)
        let cancelled = try await http.cancel(runID: "agr_test")
        #expect(cancelled.id == "agr_test")
        #expect(
            IssueReportDraftStubURLProtocol.recordedRequests().map(\.path)
                == ["/api/v1/agent-runs/agr_test", "/api/v1/agent-runs/agr_test/cancel"]
        )
    }

    @Test("A deadline reaches the live HTTP transport as a cancel POST")
    func liveDeadlinePostsCancel() async throws {
        let runID = "agr_deadline"
        IssueReportDraftStubURLProtocol.reset(replies: Self.heldRunReplies(runID: runID))
        let service = IssueReportDraftService.live(
            configuration: try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test")),
            session: Self.stubSession(),
            pollInterval: .milliseconds(1),
            deadline: .milliseconds(40)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "slow request", machineID: "machine-1")
            Issue.record("Expected a timeout")
        } catch {
            #expect(error as? IssueReportDraftError == .timedOut)
        }
        let keys = try await Self.waitForRequest("POST /api/v1/agent-runs/\(runID)/cancel")
        #expect(keys.contains("POST /api/v1/agent-runs/\(runID)/cancel"))
        #expect(keys.contains("GET /api/v1/agent-runs/\(runID)"))
        #expect(keys.filter { $0 == "POST /api/v1/agent-runs" }.count == 1)
    }

    @Test("Caller cancellation reaches the live HTTP transport as a cancel POST")
    func liveCallerCancellationPostsCancel() async throws {
        let runID = "agr_cancel"
        IssueReportDraftStubURLProtocol.reset(replies: Self.heldRunReplies(runID: runID))
        let service = IssueReportDraftService.live(
            configuration: try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test")),
            session: Self.stubSession(),
            pollInterval: .milliseconds(1),
            deadline: .seconds(5)
        )

        let task = Task { try await service.draft(kind: .bug, text: "cancel me", machineID: "machine-1") }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("Expected the draft to fail with cancellation")
            return
        }
        #expect(error as? IssueReportDraftError == .cancelled)
        let keys = try await Self.waitForRequest("POST /api/v1/agent-runs/\(runID)/cancel")
        #expect(keys.contains("POST /api/v1/agent-runs/\(runID)/cancel"))
    }

    @Test("A cancelled fetch over HTTP maps to cancellation and cancels the run")
    func liveFetchCancellationPostsCancel() async throws {
        let runID = "agr_fetch_cancel"
        var replies = Self.heldRunReplies(runID: runID)
        replies["GET /api/v1/agent-runs/\(runID)"] = .init(status: 0, body: "", failWithCancellation: true)
        IssueReportDraftStubURLProtocol.reset(replies: replies)
        let service = IssueReportDraftService.live(
            configuration: try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test")),
            session: Self.stubSession(),
            pollInterval: .milliseconds(1),
            deadline: .seconds(5)
        )

        do {
            _ = try await service.draft(kind: .bug, text: "fetch cancel", machineID: "machine-1")
            Issue.record("Expected cancellation")
        } catch {
            #expect(error as? IssueReportDraftError == .cancelled)
        }
        let keys = try await Self.waitForRequest("POST /api/v1/agent-runs/\(runID)/cancel")
        #expect(keys.contains("POST /api/v1/agent-runs/\(runID)/cancel"))
    }

    // MARK: - Helpers

    private static func heldRunReplies(runID: String) -> [String: IssueReportDraftStubURLProtocol.Reply] {
        [
            "GET /api/v1/agent-runs/capabilities": .init(
                status: 200,
                body: #"{"ok":true,"profiles":["issue-report-draft-v1"]}"#
            ),
            "POST /api/v1/agent-runs": .init(status: 202, body: runEnvelope(status: "running", id: runID)),
            "GET /api/v1/agent-runs/\(runID)": .init(status: 0, body: "", hold: true),
            "POST /api/v1/agent-runs/\(runID)/cancel": .init(
                status: 200,
                body: runEnvelope(status: "cancelled", id: runID)
            ),
        ]
    }

    /// Polls the recorded transport keys until `key` appears or the timeout
    /// elapses; the best-effort cancel is intentionally fire-and-forget.
    private static func waitForRequest(_ key: String, timeout: Duration = .seconds(2)) async throws -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let keys = recordedKeys()
            if keys.contains(key) { return keys }
            try await Task.sleep(for: .milliseconds(2))
        }
        return recordedKeys()
    }

    private static func recordedKeys() -> [String] {
        IssueReportDraftStubURLProtocol.recordedRequests().map { "\($0.method) \($0.path)" }
    }

    private static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssueReportDraftStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    fileprivate static func makeRun(
        status: HeadlessAgentRunStatus,
        response: String? = nil,
        error: String? = nil
    ) -> HeadlessAgentRun {
        HeadlessAgentRun(
            id: "run-1",
            status: status,
            mode: .ask,
            model: nil,
            thinkingLevel: "off",
            prompt: "request",
            cwd: nil,
            response: response,
            error: error,
            createdAt: "2026-09-23T12:00:00Z",
            startedAt: nil,
            finishedAt: nil,
            sessionID: nil,
            sessionFile: nil,
            costUSD: nil,
            promotedWorkspaceID: nil,
            promotedPaneID: nil,
            attachments: nil,
            steps: nil,
            stepsTruncated: nil,
            threadRootRunId: nil
        )
    }

    private static func runEnvelope(
        status: String,
        response: String? = nil,
        error: String? = nil,
        id: String = "run-1"
    ) -> String {
        var run: [String: Any] = [
            "id": id,
            "status": status,
            "prompt": "request",
            "createdAt": "2026-09-23T12:00:00Z",
        ]
        if let response { run["response"] = response }
        if let error { run["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "run": run])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Records every call and serves scripted terminal states so the service's
/// one-shot, bounded behavior is asserted without a live provider.
@MainActor
private final class DraftTransportSpy {
    var capabilityProfiles: [String] = [IssueReportDraftProfile.identifier]
    var capabilityError: (any Error)?
    var capabilityDelay: Duration?
    var startError: (any Error)?
    var startDelay: Duration?
    var startRun = IssueReportDraftServiceTests.makeRun(status: .completed, response: #"{"title":"T","body":"B"}"#)
    var fetchResponses: [HeadlessAgentRun] = []
    var fetchDelays: [Duration] = []
    var fetchError: (any Error)?
    var cancelError: (any Error)?
    var cancelDelay: Duration?
    private(set) var capabilityCalls: [String] = []
    private(set) var startCalls: [(machineID: String, request: IssueReportDraftRequest)] = []
    private(set) var fetchCalls: [String] = []
    private(set) var cancelCalls: [String] = []

    var transport: IssueReportDraftTransport {
        IssueReportDraftTransport(
            capabilities: { [weak self] machineID in
                guard let self else { throw APIError.invalidResponse }
                self.capabilityCalls.append(machineID)
                if let delay = self.capabilityDelay { try await Task.sleep(for: delay) }
                if let error = self.capabilityError { throw error }
                return AssistantCapabilities(profiles: self.capabilityProfiles)
            },
            start: { [weak self] machineID, request in
                guard let self else { throw APIError.invalidResponse }
                self.startCalls.append((machineID, request))
                if let delay = self.startDelay { try await Task.sleep(for: delay) }
                if let error = self.startError { throw error }
                return self.startRun
            },
            fetch: { [weak self] _, runID in
                guard let self else { throw APIError.invalidResponse }
                self.fetchCalls.append(runID)
                if !self.fetchDelays.isEmpty { try await Task.sleep(for: self.fetchDelays.removeFirst()) }
                if let error = self.fetchError { throw error }
                if self.fetchResponses.isEmpty { return self.startRun }
                return self.fetchResponses.removeFirst()
            },
            cancel: { [weak self] _, runID in
                guard let self else { throw APIError.invalidResponse }
                self.cancelCalls.append(runID)
                if let delay = self.cancelDelay { try await Task.sleep(for: delay) }
                if let error = self.cancelError { throw error }
                return self.startRun
            }
        )
    }
}

/// Serves scripted agent-run replies while recording every request, so the
/// restricted body and per-path timeouts can be asserted without a server.
private final class IssueReportDraftStubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let body: String
        /// Keep the request pending until URLSession cancels it; used to test
        /// deadline and caller cancellation reaching the transport.
        var hold: Bool = false
        /// Fail the request as `URLError(.cancelled)` without responding.
        var failWithCancellation: Bool = false
    }

    struct RecordedRequest: Sendable {
        let path: String
        let method: String
        let body: Data
        let contentType: String?
        let authorization: String?
        let timeout: TimeInterval
    }

    private struct State: Sendable {
        var replies: [String: Reply] = [:]
        var requests: [RecordedRequest] = []
    }

    private static let state = Mutex(State())

    static func reset(replies: [String: Reply]) {
        state.withLock { $0 = State(replies: replies, requests: []) }
    }

    static func recordedRequests() -> [RecordedRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let recorded = RecordedRequest(
            path: path,
            method: method,
            body: Self.readBody(request),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            timeout: request.timeoutInterval
        )
        let match: Reply? = Self.state.withLock { current in
            current.requests.append(recorded)
            return current.replies["\(method) \(path)"]
        }
        if let match, match.failWithCancellation {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if let match, match.hold {
            // Never answer; the URLSession task's cancellation (from the shared
            // deadline or the caller) ends this request through stopLoading.
            return
        }
        let (status, reply) = match.map { ($0.status, $0.body) }
            ?? (404, #"{"ok":false,"error":{"code":"not_found","message":"Not found"}}"#)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols a body stream, not `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
