import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Saved HUD chat HTTP client", .serialized)
struct HudChatAPIClientTests {
    @Test("Uses authenticated capability, catalog, paginated history, and start routes")
    func routesAndBodies() async throws {
        HudChatURLProtocol.recorder.reset()
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-token")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HudChatURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = HerdrAPIClient(configuration: configuration, session: session)

        let capabilities = try await client.fetchHudChatCapabilities()
        let catalog = try await client.fetchHudChats(query: "release notes", offset: 50)
        let history = try await client.fetchHudChat(id: "agr_root", offset: 100)
        let started = try await client.startHudChat(
            HudChatStartRequest(
                prompt: "Continue safely",
                cwd: nil,
                model: "openai-codex/gpt-5.6-sol",
                thinkingLevel: "high",
                continueFromRunId: "agr_latest"
            )
        )

        #expect(capabilities.hudChatWorkingDirectory)
        #expect(catalog.nextOffset == nil)
        #expect(history.rootRunId == "agr_root")
        #expect(started.run.threadRootRunId == "agr_root")

        let requests = HudChatURLProtocol.recorder.requests()
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" })
        #expect(requests[0].url?.path == "/api/v1/agent-runs/capabilities")
        #expect(requests[1].url?.path == "/api/v1/hud-chats")
        let catalogItems = URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(catalogItems?.first(where: { $0.name == "q" })?.value == "release notes")
        #expect(catalogItems?.first(where: { $0.name == "offset" })?.value == "50")
        #expect(requests[2].url?.path == "/api/v1/hud-chats/agr_root")
        #expect(URLComponents(url: try #require(requests[2].url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "100")
        #expect(requests[3].httpMethod == "POST")
        #expect(requests[3].url?.path == "/api/v1/agent-runs")
        let body = try #require(requests[3].httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["profile"] as? String == "hud-chat-v1")
        #expect(payload["continueFromRunId"] as? String == "agr_latest")
        #expect(payload["cwd"] == nil)
    }

    @Test("Rejects unsafe history ids before a request is sent")
    func rejectsUnsafeID() async throws {
        HudChatURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: ""))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HudChatURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = HerdrAPIClient(configuration: configuration, session: session)

        await #expect(throws: APIError.self) {
            _ = try await client.fetchHudChat(id: "../other", offset: 0)
        }
        #expect(HudChatURLProtocol.recorder.requests().isEmpty)
    }
}

private final class HudChatURLProtocol: URLProtocol {
    static let recorder = HudChatRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.recorder.record(captured)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: request.httpMethod == "POST" ? 202 : 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func responseData(for request: URLRequest) -> Data {
        switch request.url?.path {
        case "/api/v1/agent-runs/capabilities":
            Data(#"{"profiles":["hud-chat-v1"],"hudChatWorkingDirectory":true}"#.utf8)
        case "/api/v1/hud-chats":
            Data(#"{"chats":[],"nextOffset":null}"#.utf8)
        case "/api/v1/hud-chats/agr_root":
            Data(#"{"turns":[],"rootRunId":"agr_root","latestRunId":"agr_latest","promotedPaneId":null,"nextOffset":null}"#.utf8)
        default:
            Data(#"{"ok":true,"run":{"id":"agr_new","status":"queued","mode":"act","prompt":"Continue safely","cwd":"/srv/example","response":null,"error":null,"createdAt":"2026-09-17T00:00:00Z","threadRootRunId":"agr_root"}}"#.utf8)
        }
    }
}

private final class HudChatRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    func reset() { lock.withLock { recorded = [] } }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
    func requests() -> [URLRequest] { lock.withLock { recorded } }
}
