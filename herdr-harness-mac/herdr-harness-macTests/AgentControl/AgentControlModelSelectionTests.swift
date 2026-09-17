import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

struct AgentControlModelSelectionTests {
    @Test("Model action sends the exact provider and model without a UI confirmation or fallback")
    func exactModelSelection() async throws {
        ModelSelectionURLProtocol.requests.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSelectionURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: try #require(ServerConfiguration(urlString: "https://synthetic.example.invalid", token: "synthetic-token")),
            session: URLSession(configuration: configuration)
        )

        try await client.setPiModel(paneID: "w1:p2", provider: "synthetic-provider", modelID: "model-exact")

        let request = try #require(ModelSelectionURLProtocol.requests.withLock { $0.first })
        #expect(request.url?.path == "/api/v1/panes/w1:p2/pi/model")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["provider": "synthetic-provider", "id": "model-exact"])
    }
}

private final class ModelSelectionURLProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"accepted":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
