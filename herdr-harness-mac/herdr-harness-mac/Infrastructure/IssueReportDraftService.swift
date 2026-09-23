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
        session: URLSession = .shared
    ) -> IssueReportDraftService {
        let http = IssueReportDraftHTTPClient(configuration: configuration, session: session)
        return IssueReportDraftService(
            transport: IssueReportDraftTransport(
                capabilities: { _ in try await http.capabilities() },
                start: { _, request in try await http.start(request) },
                fetch: { _, runID in try await http.fetch(runID: runID) },
                cancel: { _, runID in try await http.cancel(runID: runID) }
            )
        )
    }

    func availability(for machineID: String) async -> IssueReportDraftAvailability {
        guard !machineID.isEmpty else { return .unavailable(IssueReportDraftError.noCompanion.localizedDescription) }
        do {
            let capabilities = try await transport.capabilities(machineID)
            return capabilities.profiles.contains(IssueReportDraftProfile.identifier)
                ? .available
                : .unsupportedCompanion
        } catch is CancellationError {
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

        // Preflight the exact companion's advertised profile before sending.
        // An older companion must never receive this prompt through a generic
        // route that could run it with tools.
        let capabilities: AssistantCapabilities
        do {
            capabilities = try await transport.capabilities(machineID)
        } catch is CancellationError {
            throw IssueReportDraftError.cancelled
        } catch {
            throw IssueReportDraftError.companionUnavailable(error.localizedDescription)
        }
        guard capabilities.profiles.contains(IssueReportDraftProfile.identifier) else {
            throw IssueReportDraftError.unsupportedCompanion
        }

        let run: HeadlessAgentRun
        do {
            run = try await transport.start(machineID, IssueReportDraftRequest(kind: kind, text: text))
        } catch is CancellationError {
            throw IssueReportDraftError.cancelled
        } catch {
            throw IssueReportDraftError.startFailed(error.localizedDescription)
        }

        let finished = try await pollToCompletion(run, machineID: machineID)
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

    /// Polls one started run to a terminal status. A cancellation or an
    /// expired deadline cancels the remote run and throws; a failed poll ends
    /// the request instead of silently starting another one.
    private func pollToCompletion(
        _ run: HeadlessAgentRun,
        machineID: String
    ) async throws -> HeadlessAgentRun {
        var current = run
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)
        while !current.status.isTerminal {
            if Task.isCancelled {
                await cancelQuietly(runID: current.id, machineID: machineID)
                throw IssueReportDraftError.cancelled
            }
            if clock.now >= deadlineInstant {
                await cancelQuietly(runID: current.id, machineID: machineID)
                throw IssueReportDraftError.timedOut
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                await cancelQuietly(runID: current.id, machineID: machineID)
                throw IssueReportDraftError.cancelled
            }
            do {
                current = try await transport.fetch(machineID, current.id)
            } catch is CancellationError {
                await cancelQuietly(runID: current.id, machineID: machineID)
                throw IssueReportDraftError.cancelled
            } catch {
                throw IssueReportDraftError.runFailed(error.localizedDescription)
            }
        }
        return current
    }

    /// Best-effort stop of a run the client is abandoning. A failure here must
    /// not mask the original timeout or cancellation.
    private func cancelQuietly(runID: String, machineID: String) async {
        _ = try? await transport.cancel(machineID, runID)
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
