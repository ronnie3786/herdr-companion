import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Pane retirement contract", .serialized)
struct PaneRetirementTests {
    private func fixture(responses: [String: RetirementStubResponse]) throws -> (HerdrAPIClient, HerdrPane) {
        RetirementURLProtocol.state.withLock { $0 = .init(responses: responses) }
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RetirementURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data(#"{"pane_id":"w1:p1","terminal_id":"term_1","workspace_id":"w1","tab_id":"w1:t1","pi_semantic":{"available":true,"connected":true,"protocol_version":1,"session_id":"synthetic-session"}}"#.utf8))
        return (client, pane.stamped(machineID: "desktop"))
    }

    private var capability: RetirementStubResponse {
        .init(json: #"{"ok":true,"capabilities":["pane-retirement-v1"]}"#)
    }

    private var success: RetirementStubResponse {
        .init(json: #"{"ok":true,"closedPaneId":"w1:p1","workspaceId":"w1","tabId":"w1:t1","nextPaneId":"w1:p2","reservedShell":true,"warnings":[]}"#)
    }

    @Test("Older servers never receive a destructive fallback")
    func oldServer() async throws {
        let (client, pane) = try fixture(responses: ["/api/v1": .init(json: #"{"ok":true}"#)])
        await #expect(throws: APIError.self) { try await client.retirePiPane(pane, requestID: "request-1") }
        let requests = RetirementURLProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.url?.path } == ["/api/v1"])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("Retirement sends stable terminal/session identity through one server operation")
    func retirementRequest() async throws {
        let path = "/api/v1/panes/w1:p1/end-pi-and-close"
        let (client, pane) = try fixture(responses: ["/api/v1": capability, path: success])
        let result = try await client.retirePiPane(pane, requestID: "request-1")
        #expect(result.reservedShell)
        #expect(result.nextPaneID == "w1:p2")
        let requests = RetirementURLProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.url?.path } == ["/api/v1", path])
        let request = try #require(requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        let body = try #require(RetirementURLProtocol.body(request))
        #expect(body["requestId"] as? String == "request-1")
        #expect(body["terminalId"] as? String == "term_1")
        #expect(body["sessionId"] as? String == "synthetic-session")
        #expect(HerdrAPIClient.timeoutInterval(path: path, method: "POST") >= 60)
    }

    @Test("A failed or uncertain retirement is not repeated or followed by DELETE", arguments: [409, 504])
    func failedRequest(status: Int) async throws {
        let path = "/api/v1/panes/w1:p1/end-pi-and-close"
        let (client, pane) = try fixture(responses: ["/api/v1": capability, path: .init(status: status, json: #"{"ok":false,"error":{"message":"Pane left open"}}"#)])
        await #expect(throws: APIError.self) { try await client.retirePiPane(pane, requestID: "request-1") }
        #expect(RetirementURLProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test("A malformed destination is not accepted as a successful close")
    func invalidDestination() async throws {
        let path = "/api/v1/panes/w1:p1/end-pi-and-close"
        let (client, pane) = try fixture(responses: ["/api/v1": capability, path: .init(json: success.json.replacingOccurrences(of: "w1:p2", with: "w1:p1"))])
        await #expect(throws: APIError.self) { try await client.retirePiPane(pane, requestID: "request-1") }
    }

    @Test("Empty-folder actions reuse the reserved terminal", arguments: [false, true])
    func reuseShell(startPi: Bool) async throws {
        let path = "/api/v1/panes/w1:p1/reserved-shell"
        let (client, pane) = try fixture(responses: ["/api/v1": capability, path: .init(json: #"{"ok":true}"#)])
        try await client.openReservedShell(pane, startPi: startPi)
        let requests = RetirementURLProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.url?.path } == ["/api/v1", path])
        let request = try #require(requests.last)
        let body = try #require(RetirementURLProtocol.body(request))
        #expect(body["action"] as? String == (startPi ? "pi" : "shell"))
        #expect(body["terminalId"] as? String == "term_1")
    }

    @MainActor
    @Test("The empty-folder view renders at normal and enlarged text sizes", arguments: [HerdrFontScale.medium, .xxxLarge])
    func emptyFolderRendering(scale: HerdrFontScale) throws {
        let suite = "PaneRetirementRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data(#"{"pane_id":"w1:p2","terminal_id":"term_2","workspace_id":"w1","tab_id":"w1:t1","cwd":"/projects/sample","reserved_shell":true}"#.utf8))
        let renderer = ImageRenderer(content: ReservedShellView(model: model, pane: pane)
            .environment(\.herdrFontScale, scale)
            .frame(width: 460, height: 520))
        #expect(renderer.nsImage != nil)
    }

    @Test("Only an explicit reservation produces the empty state and survives coding")
    func reservationDecoding() throws {
        let raw = #"{"pane_id":"w1:p2","terminal_id":"term_2","workspace_id":"w1","tab_id":"w1:t1","title":"Shell startup"}"#
        let ordinary = try JSONDecoder().decode(HerdrPane.self, from: Data(raw.utf8))
        let reserved = try JSONDecoder().decode(HerdrPane.self, from: Data(raw.dropLast().appending(",\"reserved_shell\":true}").utf8))
        #expect(!ordinary.reservedShell)
        #expect(reserved.reservedShell)
        #expect(reserved.displayTitle == "No open chats")
        #expect(!ordinary.isEqualIgnoringRevision(to: reserved))
        let roundtrip = try JSONDecoder().decode(HerdrPane.self, from: JSONEncoder().encode(reserved))
        #expect(roundtrip == reserved)
        #expect(reserved.stamped(machineID: "desktop").scopedTabID == "desktop|w1:t1")
    }
}

private struct RetirementStubResponse: Sendable {
    var status = 200
    let json: String
}

private struct RetirementStubState: Sendable {
    var responses: [String: RetirementStubResponse] = [:]
    var requests: [URLRequest] = []
}

private final class RetirementURLProtocol: URLProtocol {
    static let state = Mutex(RetirementStubState())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Materialize the body stream before URLSession releases it.
        var captured = request
        captured.httpBody = Self.bodyData(request)
        let stub = Self.state.withLock { state in
            state.requests.append(captured)
            return state.responses[request.url?.path ?? ""] ?? .init(status: 500, json: "{}")
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ request: URLRequest) -> [String: Any]? {
        bodyData(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
