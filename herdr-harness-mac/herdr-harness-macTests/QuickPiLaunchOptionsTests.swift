import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Quick Pi launch options", .serialized)
struct QuickPiLaunchOptionsTests {
    @Test("Encodes model, thinking level, and focus when a workspace launch provides them")
    func encodesLaunchOptions() throws {
        let request = QuickPiSessionRequest(
            label: "hud chat",
            requestID: "request-1",
            workspaceID: "w-main",
            cwd: "~",
            reuseNamedTab: false,
            model: QuickPiSessionModel(provider: "anthropic", id: "claude-sonnet"),
            thinkingLevel: "high",
            focus: false
        )
        let object = try Self.object(from: request)
        #expect(object["workspaceId"] as? String == "w-main")
        #expect(object["cwd"] as? String == "~")
        #expect(object["reuseNamedTab"] as? Bool == false)
        #expect(object["focus"] as? Bool == false)
        #expect(object["thinkingLevel"] as? String == "high")
        let model = try #require(object["model"] as? [String: Any])
        #expect(model["provider"] as? String == "anthropic")
        #expect(model["id"] as? String == "claude-sonnet")
        #expect(model["name"] == nil)
    }

    @Test("A request without launch options keeps the legacy payload")
    func legacyPayloadOmitsLaunchOptions() throws {
        let request = QuickPiSessionRequest(label: "hud", requestID: "request-2")
        let object = try Self.object(from: request)
        #expect(object["model"] == nil)
        #expect(object["thinkingLevel"] == nil)
        #expect(object["focus"] == nil)
        #expect(object["workspaceId"] == nil)
        #expect(object["cwd"] == nil)
    }

    @Test("The API client forwards launch options through the quick-session body")
    func clientForwardsLaunchOptions() async throws {
        QuickLaunchURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [QuickLaunchURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )

        let response = try await client.createQuickPiSession(
            label: "hud chat",
            requestID: "launch-1",
            workspaceID: "w-main",
            cwd: "/Users/example/project",
            reuseNamedTab: false,
            model: QuickPiSessionModel(provider: "openai-codex", id: "gpt-5.6-luna"),
            thinkingLevel: "max",
            focus: false
        )

        #expect(response.paneID == "w-main:p1")
        let recorded = try #require(QuickLaunchURLProtocol.recorder.requests().first)
        #expect(recorded.path == "/api/v1/quick-sessions/pi")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(recorded.body.utf8)) as? [String: Any]
        )
        #expect(object["workspaceId"] as? String == "w-main")
        #expect(object["cwd"] as? String == "/Users/example/project")
        #expect(object["reuseNamedTab"] as? Bool == false)
        #expect(object["focus"] as? Bool == false)
        #expect(object["thinkingLevel"] as? String == "max")
        let model = try #require(object["model"] as? [String: Any])
        #expect(model["provider"] as? String == "openai-codex")
        #expect(model["id"] as? String == "gpt-5.6-luna")
    }

    @Test("Decodes the launch-options capability only when the companion advertises it")
    func decodesLaunchOptionsCapability() throws {
        let supported = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: Data(#"{"capabilities":["pane-retirement-v1","quick-session-launch-options-v1"]}"#.utf8)
        )
        #expect(supported.supportsQuickSessionLaunchOptions)

        let legacy = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: Data(#"{"capabilities":["pane-retirement-v1"]}"#.utf8)
        )
        #expect(!legacy.supportsQuickSessionLaunchOptions)

        let absent = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: Data(#"{"ok":true}"#.utf8)
        )
        #expect(!absent.supportsQuickSessionLaunchOptions)
    }

    private static func object(from request: QuickPiSessionRequest) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }
}

private final class QuickLaunchURLProtocol: URLProtocol {
    static let recorder = QuickLaunchRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        Self.recorder.record(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: body)
        let requestID = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["requestId"] as? String ?? ""
        let payload: [String: Any] = [
            "ok": true,
            "workspace_id": "w-main",
            "tab_id": "w-main:t1",
            "pane_id": "w-main:p1",
            "created_workspace": false,
            "created_tab": true,
            "created_pane": true,
            "pi_extension_attached": true,
            "request_id": requestID,
        ]
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let data = try? JSONSerialization.data(withJSONObject: payload)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class QuickLaunchRequestRecorder: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let path: String
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
    }

    func record(method: String, path: String, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Request(method: method, path: path, body: String(decoding: body, as: UTF8.self)))
    }

    func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
