import Foundation

/// A refusal from the companion's simulator routes, keeping its error code
/// (for example `simulator_capacity` or `simulator_storage_low`).
struct FirstMateSimulatorError: Error, LocalizedError, Equatable, Sendable {
    let status: Int?
    let code: String
    let message: String
    /// For `simulator_capacity`: the previews already running.
    var running: [FirstMateSimulatorPreview] = []

    var errorDescription: String? { message }

    /// Nothing will change by asking again without a new decision.
    var isDefinite: Bool {
        guard let status else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }
}

/// The companion's simulator routes on one machine
/// (`first-mate-simulator-previews-v1`). SimPortal itself is never contacted
/// from the Mac: the companion holds its credential and relays the stream.
struct FirstMateSimulatorAPI: Sendable {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    /// Feature, build and preview IDs are plain ASCII tokens; anything else never reaches a URL.
    static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x3A || byte == 0x2D
        }
    }

    func builds(featureID: String) async throws -> FirstMateSimulatorBuildList {
        try await send("GET", try path(featureID, "simulator-builds"))
    }

    func open(featureID: String, buildID: String, requestID: String) async throws -> FirstMateSimulatorOpenResponse {
        try await send("POST", try path(featureID, "simulator-builds", buildID, "preview"), body: ["request_id": requestID])
    }

    func preview(featureID: String, previewID: String) async throws -> FirstMateSimulatorPreviewDetail {
        try await send("GET", try path(featureID, "simulator-previews", previewID))
    }

    func stop(featureID: String, previewID: String, requestID: String) async throws -> FirstMateSimulatorPreviewEnvelope {
        try await send("POST", try path(featureID, "simulator-previews", previewID, "stop"),
                       body: ["request_id": requestID, "mode": "shutdown"])
    }

    /// The WebSocket upgrade for the preview's exact simulator, with the
    /// companion credential in a header (never in the URL).
    func streamRequest(featureID: String, previewID: String) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw FirstMateSimulatorError(status: nil, code: "invalid_request", message: "The companion address is invalid.")
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path += try path(featureID, "simulator-previews", previewID, "stream")
        guard let url = components.url else {
            throw FirstMateSimulatorError(status: nil, code: "invalid_request", message: "The companion address is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Whether the Mac reaches this companion over loopback, which decides
    /// which of SimPortal's browser links can work here.
    var isLocal: Bool {
        let host = (configuration.baseURL.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private func path(_ featureID: String, _ parts: String...) throws -> String {
        let segments = [featureID] + parts
        guard segments.allSatisfy(Self.isIdentifier) else {
            throw FirstMateSimulatorError(status: 404, code: "not_found", message: "That simulator build is not available.")
        }
        return "/api/v1/first-mate/features/" + segments.joined(separator: "/")
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> Response {
        var request = URLRequest(url: configuration.baseURL.appending(path: path), timeoutInterval: method == "GET" ? 20 : 45)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FirstMateSimulatorError(status: nil, code: "companion_unreachable",
                                          message: "Couldn't reach this machine's companion.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw FirstMateSimulatorError(status: nil, code: "invalid_response", message: "The companion sent an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FirstMateSimulatorError(status: http.statusCode, code: "invalid_response",
                                          message: "The companion sent a simulator response this version can't read.")
        }
    }

    static func error(status: Int, data: Data) -> FirstMateSimulatorError {
        struct Envelope: Decodable {
            struct Details: Decodable { let running: [FirstMateSimulatorPreview]? }
            struct Body: Decodable {
                let code: String?
                let message: String?
                let details: Details?
            }
            let error: Body?
        }
        let body = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let fallback = status == 404
            ? "This companion doesn't have simulator previews. Update the companion package on that machine."
            : "The companion refused the request (HTTP \(status))."
        return FirstMateSimulatorError(status: status, code: body?.code ?? "http_\(status)",
                                       message: body?.message ?? fallback, running: body?.details?.running ?? [])
    }
}
