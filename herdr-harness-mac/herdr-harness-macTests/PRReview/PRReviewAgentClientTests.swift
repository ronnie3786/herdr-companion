import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("PR Review agent transport", .serialized) @MainActor
struct PRReviewAgentClientTests {
    @Test("Creating and batching agents use explicit agent IDs and preserve the legacy endpoints")
    func wireContract() async throws {
        let config = try #require(ServerConfiguration(urlString: "https://example.invalid/prefix", token: "synthetic-token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PRReviewAgentsURLProtocol.self]
        let client = HerdrAPIClient(configuration: config, session: URLSession(configuration: configuration))
        let snapshot = PRReviewAgentDemo.snapshot()
        PRReviewAgentsURLProtocol.state.withLock { $0 = .init(response: try! JSONEncoder().encode(snapshot)) }
        let created = try await client.createPRReview(url: snapshot.review.url, agentIDs: ["catalog-data"], requestID: "create-synthetic")
        #expect(created.consolidation?.inputRunIDs.count == 3)
        var request = try #require(PRReviewAgentsURLProtocol.state.withLock { $0.request })
        #expect(request.path == "/prefix/api/v1/pr-reviews")
        #expect(request.authorization == "Bearer synthetic-token")
        var body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["agent_ids"] as? [String] == ["catalog-data"])
        #expect(body["skill_ids"] == nil)
        #expect(body["url"] as? String == snapshot.review.url)
        #expect(body["request_id"] as? String == "create-synthetic")

        let response = try JSONSerialization.data(withJSONObject: ["runs": JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.runs))])
        PRReviewAgentsURLProtocol.state.withLock { $0 = .init(response: response) }
        let runs = try await client.createPRReviewAgentRuns(id: snapshot.review.id, agentIDs: ["catalog-data", "catalog-interface"], requestID: "batch-synthetic")
        #expect(runs.first?.agentName == "Comprehensive")
        request = try #require(PRReviewAgentsURLProtocol.state.withLock { $0.request })
        #expect(request.path == "/prefix/api/v1/pr-reviews/prr_demo42/runs")
        body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["agent_ids"] as? [String] == ["catalog-data", "catalog-interface"])
        #expect(body["skill_id"] == nil)
        #expect(body["request_id"] as? String == "batch-synthetic")
    }
}

private final class PRReviewAgentsURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var authorization: String?
        var body: Data
    }
    struct State: Sendable {
        var response = Data()
        var request: Request?
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? readBody(request.httpBodyStream)
        let responseData = Self.state.withLock {
            $0.request = Request(path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
            return $0.response
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func readBody(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
