import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("PR Review client contract", .serialized)
struct PRReviewClientContractTests {
    @Test("Run output decodes lines and uses the output endpoint")
    func runOutputUsesLinesResponse() async throws {
        PRReviewRunOutputURLProtocol.requests.withLock { $0.removeAll() }
        let configuration = try #require(ServerConfiguration(urlString: "https://example.invalid", token: "synthetic-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewRunOutputURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))

        let output = try await client.prReviewRunOutput(
            reviewID: "prr_0123456789ab",
            runID: "prun_0123456789ab",
            lines: 17
        )

        let requests = PRReviewRunOutputURLProtocol.requests.withLock { $0 }
        #expect(output == "first fictional line\nsecond fictional line")
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/api/v1/pr-reviews/prr_0123456789ab/runs/prun_0123456789ab/output")
        #expect(URLComponents(url: try #require(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "lines" })?.value == "17")
    }
}

private final class PRReviewRunOutputURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let body = Data("{\"ok\":true,\"run_id\":\"prun_0123456789ab\",\"lines\":[\"first fictional line\",\"second fictional line\"],\"source\":\"stdout\"}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
