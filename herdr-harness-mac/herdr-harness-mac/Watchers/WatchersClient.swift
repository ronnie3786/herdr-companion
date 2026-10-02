import Foundation

protocol WatchersClient: Sendable {
    func watchersRequest(_ path: [String], method: String, body: [String: PiJSONValue]?, query: [URLQueryItem]) async throws -> [String: PiJSONValue]
}
extension WatchersClient {
    func watchersGet(_ path: [String] = [], query: [URLQueryItem] = []) async throws -> [String: PiJSONValue] {
        try await watchersRequest(path, method: "GET", body: nil, query: query)
    }
    func watchersMutate(_ path: [String], method: String = "POST", body: [String: PiJSONValue] = [:], requestID: String = UUID().uuidString) async throws -> [String: PiJSONValue] {
        var body = body; body["request_id"] = .string(requestID)
        return try await watchersRequest(path, method: method, body: body, query: [])
    }
}
