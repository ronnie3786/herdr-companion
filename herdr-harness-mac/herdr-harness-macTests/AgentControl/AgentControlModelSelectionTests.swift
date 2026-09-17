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
        #expect(request.path == "/api/v1/panes/w1:p2/pi/model")
        #expect(request.method == "POST")
        let body = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["provider": "synthetic-provider", "id": "model-exact"])
    }
}

private final class ModelSelectionURLProtocol: URLProtocol {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let body: Data?
    }

    static let requests = Mutex<[RecordedRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock {
            $0.append(RecordedRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                body: request.httpBody ?? Self.data(from: request.httpBodyStream)
            ))
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func data(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
