import Foundation

protocol AgentControlTransport: Sendable {
    func capabilities() async throws -> AgentControlCapabilitiesResponse
    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse
    func poll(clientId: String, request: AgentControlPollRequest) async throws -> AgentControlPollResponse
    func acknowledge(clientId: String, requestId: String, request: AgentControlResultRequest) async throws -> AgentControlResultResponse
}

private final class AgentControlRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor LiveAgentControlTransport: AgentControlTransport {
    private struct ErrorEnvelope: Decodable {
        let error: AgentControlCommandError?
    }

    private let configuration: ServerConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: ServerConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 8
            settings.timeoutIntervalForResource = 12
            settings.waitsForConnectivity = false
            self.session = URLSession(configuration: settings, delegate: AgentControlRedirectBlocker(), delegateQueue: nil)
        }
    }

    func capabilities() async throws -> AgentControlCapabilitiesResponse {
        try await send(path: "/api/v1/control/capabilities", method: "GET", body: Optional<Data>.none)
    }

    func register(_ request: AgentControlRegistrationRequest) async throws -> AgentControlRegistrationResponse {
        try await send(path: "/api/v1/ui/clients/register", method: "POST", body: encoder.encode(request))
    }

    func poll(clientId: String, request: AgentControlPollRequest) async throws -> AgentControlPollResponse {
        try await send(path: "/api/v1/ui/clients/\(try safeSegment(clientId))/poll", method: "POST", body: encoder.encode(request))
    }

    func acknowledge(
        clientId: String,
        requestId: String,
        request: AgentControlResultRequest
    ) async throws -> AgentControlResultResponse {
        let client = try safeSegment(clientId)
        let requestID = try safeSegment(requestId)
        return try await send(
            path: "/api/v1/ui/clients/\(client)/commands/\(requestID)/result",
            method: "POST",
            body: encoder.encode(request)
        )
    }

    private func safeSegment(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw AgentControlCommandError.invalid("Invalid control identifier.") }
        return encoded
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(ErrorEnvelope.self, from: data).error
            if let detail { throw detail }
            throw APIError.server(status: http.statusCode, message: "Agent control request failed.")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
