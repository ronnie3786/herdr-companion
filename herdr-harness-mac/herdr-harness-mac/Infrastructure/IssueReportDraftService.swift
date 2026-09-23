import Foundation

/// The per-companion seams one drafting request needs. The live wiring is
/// built by `HerdrAppModel` from the exact connected client's configuration;
/// tests inject synthetic closures so no network, Pi provider, or live
/// microphone is involved.
@MainActor
struct IssueReportDraftTransport {
    var capabilities: @MainActor (String) async throws -> AssistantCapabilities
    var start: @MainActor (String, IssueReportDraftRequest) async throws -> HeadlessAgentRun
    var fetch: @MainActor (String, String) async throws -> HeadlessAgentRun
    var cancel: @MainActor (String, String) async throws -> HeadlessAgentRun
}

/// The drafting half of the smart-input state. Unit tests use the protocol
/// directly; the app uses `IssueReportDraftService` with the live transport.
@MainActor
protocol IssueReportDrafting: AnyObject {
    func availability(for machineID: String) async -> IssueReportDraftAvailability
    func draft(kind: IssueReportKind, text: String, machineID: String) async throws -> IssueReportDraftOutput
}

/// Runs exactly one bounded, tool-free drafting ask against one exact
/// companion.
///
/// `draft` preflights the companion's advertised `issue-report-draft-v1`
/// profile before anything is sent, starts one run with the Pi default and
/// thinking Off, and polls to a finite deadline. A timeout or a cancelled
/// caller best-effort cancels the remote run; nothing here ever retries, swaps
/// in a different model or machine, or falls back to a generic agent profile.
@MainActor
final class IssueReportDraftService: IssueReportDrafting {
    private let transport: IssueReportDraftTransport
    private let pollInterval: Duration
    private let deadline: Duration
    /// Internal bound for the detached best-effort remote cancel.
    private static let cancelTimeout: Duration = .seconds(5)

    init(
        transport: IssueReportDraftTransport,
        pollInterval: Duration = IssueReportDraftProfile.pollInterval,
        deadline: Duration = IssueReportDraftProfile.deadline
    ) {
        self.transport = transport
        self.pollInterval = pollInterval
        self.deadline = deadline
    }

    /// The live transport for one exact companion, authenticated with the same
    /// configuration the rest of the app uses for that machine.
    static func live(
        configuration: ServerConfiguration,
        session: URLSession = .shared,
        pollInterval: Duration = IssueReportDraftProfile.pollInterval,
        deadline: Duration = IssueReportDraftProfile.deadline
    ) -> IssueReportDraftService {
        let http = IssueReportDraftHTTPClient(configuration: configuration, session: session)
        return IssueReportDraftService(
            transport: IssueReportDraftTransport(
                capabilities: { _ in try await http.capabilities() },
                start: { _, request in try await http.start(request) },
                fetch: { _, runID in try await http.fetch(runID: runID) },
                cancel: { _, runID in try await http.cancel(runID: runID) }
            ),
            pollInterval: pollInterval,
            deadline: deadline
        )
    }

    func availability(for machineID: String) async -> IssueReportDraftAvailability {
        guard !machineID.isEmpty else { return .unavailable(IssueReportDraftError.noCompanion.localizedDescription) }
        do {
            let capabilities = try await transport.capabilities(machineID)
            return capabilities.profiles.contains(IssueReportDraftProfile.identifier)
                ? .available
                : .unsupportedCompanion
        } catch where Self.isCancellation(error) {
            return .unknown
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func draft(
        kind: IssueReportKind,
        text: String,
        machineID: String
    ) async throws -> IssueReportDraftOutput {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IssueReportDraftError.emptySource
        }
        if let problem = IssueReportDraftProfile.sourceProblem(text) {
            throw problem
        }
        guard !machineID.isEmpty else { throw IssueReportDraftError.noCompanion }

        // One deadline covers the preflight, the start request, and every
        // poll. Late preflight or start responses and terminal fetches that
        // arrive after it are refused instead of being accepted.
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)

        let capabilities: AssistantCapabilities
        do {
            capabilities = try await bounded(until: deadlineInstant) { [self] in
                try await transport.capabilities(machineID)
            }
        } catch {
            throw preflightFailure(error)
        }
        guard capabilities.profiles.contains(IssueReportDraftProfile.identifier) else {
            throw IssueReportDraftError.unsupportedCompanion
        }

        let run: HeadlessAgentRun
        do {
            run = try await bounded(until: deadlineInstant) { [self] in
                try await transport.start(machineID, IssueReportDraftRequest(kind: kind, text: text))
            }
        } catch {
            throw startFailure(error)
        }

        let finished = try await pollToCompletion(run, machineID: machineID, deadlineInstant: deadlineInstant)
        switch finished.status {
        case .completed, .promoted:
            let response = (finished.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { throw IssueReportDraftError.emptyOutput }
            do {
                return try IssueReportDraftOutput.parse(response)
            } catch let error as IssueReportDraftOutputError {
                throw IssueReportDraftError.invalidOutput(error)
            }
        case .failed:
            let reason = finished.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw IssueReportDraftError.runFailed(reason?.isEmpty == false ? reason! : "The drafting run failed.")
        case .cancelled:
            throw IssueReportDraftError.cancelled
        case .queued, .running:
            throw IssueReportDraftError.runFailed("The drafting run did not finish.")
        }
    }

    /// Runs one transport step inside the shared deadline. The loser of the
    /// race is cancelled, so a preflight, start, or fetch that outlives its
    /// budget cannot keep the sheet busy or deliver a late result.
    private func bounded<T: Sendable>(
        until instant: ContinuousClock.Instant,
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        guard clock.now < instant else { throw IssueReportDraftError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: instant, clock: clock)
                throw IssueReportDraftError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw IssueReportDraftError.timedOut }
            return first
        }
    }

    private func preflightFailure(_ error: any Error) -> IssueReportDraftError {
        if Self.isCancellation(error) { return .cancelled }
        if let draft = error as? IssueReportDraftError { return draft }
        return .companionUnavailable(error.localizedDescription)
    }

    private func startFailure(_ error: any Error) -> IssueReportDraftError {
        if Self.isCancellation(error) { return .cancelled }
        if let draft = error as? IssueReportDraftError { return draft }
        return .startFailed(error.localizedDescription)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let draft = error as? IssueReportDraftError, draft == .cancelled { return true }
        return false
    }

    /// Polls one started run to a terminal status inside the shared deadline.
    /// A cancellation or an expired deadline cancels the remote run and
    /// throws; an abandoned polling failure best-effort cancels too, and the
    /// request never starts a second one.
    private func pollToCompletion(
        _ run: HeadlessAgentRun,
        machineID: String,
        deadlineInstant: ContinuousClock.Instant
    ) async throws -> HeadlessAgentRun {
        let clock = ContinuousClock()
        var current = run
        while !current.status.isTerminal {
            if Task.isCancelled {
                cancelQuietly(runID: current.id, machineID: machineID)
                throw IssueReportDraftError.cancelled
            }
            do {
                try await bounded(until: deadlineInstant) { [self] in
                    try await Task.sleep(for: pollInterval)
                }
            } catch {
                if Self.isCancellation(error) || (error as? IssueReportDraftError) == .timedOut {
                    cancelQuietly(runID: current.id, machineID: machineID)
                }
                throw Self.pollFailure(error)
            }
            do {
                current = try await bounded(until: deadlineInstant) { [self] in
                    try await transport.fetch(machineID, current.id)
                }
            } catch {
                cancelQuietly(runID: current.id, machineID: machineID)
                throw Self.pollFailure(error)
            }
        }
        guard !Task.isCancelled else {
            cancelQuietly(runID: current.id, machineID: machineID)
            throw IssueReportDraftError.cancelled
        }
        guard clock.now < deadlineInstant else {
            // A terminal response that arrives after the deadline is refused:
            // the user already saw the timeout, so accepting it later would
            // contradict the sheet and the reported outcome.
            cancelQuietly(runID: current.id, machineID: machineID)
            throw IssueReportDraftError.timedOut
        }
        return current
    }

    private static func pollFailure(_ error: any Error) -> IssueReportDraftError {
        if isCancellation(error) { return .cancelled }
        if let draft = error as? IssueReportDraftError { return draft }
        return .runFailed(error.localizedDescription)
    }

    /// Best-effort stop of a run the client is abandoning.
    ///
    /// The request runs in an independent, non-cancelled task so a caller that
    /// was just cancelled can still deliver it. The service never awaits it,
    /// so cleanup cannot extend the sheet's busy state, and an internal
    /// timeout drops the request if the transport cannot answer.
    private func cancelQuietly(runID: String, machineID: String) {
        Task.detached(priority: .utility) { [self] in
            let cancel = Task { @MainActor [self] in
                _ = try? await transport.cancel(machineID, runID)
            }
            let timeout = Task {
                try? await Task.sleep(for: Self.cancelTimeout)
                cancel.cancel()
            }
            _ = await cancel.value
            timeout.cancel()
        }
    }
}

/// The restricted start body is unique to this profile, so it carries its own
/// small authenticated transport instead of routing a nonstandard body through
/// the general headless-run request. Everything else — base URL, bearer token,
/// per-path timeouts, and server error mapping — matches the app's client.
struct IssueReportDraftHTTPClient: Sendable {
    let configuration: ServerConfiguration
    let session: URLSession

    init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func capabilities() async throws -> AssistantCapabilities {
        try await perform(makeRequest(path: "/api/v1/agent-runs/capabilities", method: "GET"))
    }

    func start(_ request: IssueReportDraftRequest) async throws -> HeadlessAgentRun {
        let envelope: HeadlessAgentRunEnvelope = try await send(
            makeRequest(path: "/api/v1/agent-runs", method: "POST"),
            body: request
        )
        guard envelope.ok else { throw APIError.invalidResponse }
        return envelope.run
    }

    func fetch(runID: String) async throws -> HeadlessAgentRun {
        let envelope: HeadlessAgentRunEnvelope = try await perform(
            makeRequest(path: "/api/v1/agent-runs/\(runID)", method: "GET")
        )
        guard envelope.ok else { throw APIError.invalidResponse }
        return envelope.run
    }

    func cancel(runID: String) async throws -> HeadlessAgentRun {
        let envelope: HeadlessAgentRunEnvelope = try await send(
            makeRequest(path: "/api/v1/agent-runs/\(runID)/cancel", method: "POST"),
            body: APIActionBody()
        )
        guard envelope.ok else { throw APIError.invalidResponse }
        return envelope.run
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = HerdrAPIClient.timeoutInterval(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ request: URLRequest,
        body: Body
    ) async throws -> Response {
        var request = request
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func perform<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data))?.error.message ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private struct ServerErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let code: String
            let message: String
        }

        let error: Payload
    }
}
