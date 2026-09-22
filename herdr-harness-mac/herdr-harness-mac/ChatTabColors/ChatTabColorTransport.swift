import Foundation

/// Narrow transport for the read-only publication contract. It deliberately
/// shares no receiver token, registration, or command polling with agent
/// control: the publisher authenticates with the main API bearer and its own
/// per-server credential.
protocol ChatTabColorTransport: Sendable {
    func capabilities() async throws -> ChatTabColorCapabilitiesResponse
    func publish(
        clientId: String,
        request: ChatTabColorPublicationRequest
    ) async throws -> ChatTabColorPublicationResponse
}

private final class ChatTabColorRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow a redirect: the bearer token must not be forwarded to a
        // host the user did not configure.
        completionHandler(nil)
    }
}

actor LiveChatTabColorTransport: ChatTabColorTransport {
    private struct ErrorEnvelope: Decodable {
        let error: AgentControlCommandError?
    }

    private let configuration: ServerConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: ServerConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.configuration = configuration
        let settings = (sessionConfiguration?.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 12
        settings.waitsForConnectivity = false
        session = URLSession(
            configuration: settings,
            delegate: ChatTabColorRedirectBlocker(),
            delegateQueue: nil
        )
    }

    func capabilities() async throws -> ChatTabColorCapabilitiesResponse {
        try await send(path: "/api/v1/control/capabilities", method: "GET", body: Optional<Data>.none)
    }

    func publish(
        clientId: String,
        request: ChatTabColorPublicationRequest
    ) async throws -> ChatTabColorPublicationResponse {
        let client = try safeSegment(clientId)
        return try await send(
            path: "/api/v1/control/chat-tab-colors/\(client)",
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
            throw APIError.server(status: http.statusCode, message: "Chat tab color request failed.")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
