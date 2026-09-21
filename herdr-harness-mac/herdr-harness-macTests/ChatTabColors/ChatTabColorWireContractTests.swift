import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Chat tab color wire contract", .serialized)
struct ChatTabColorWireContractTests {
    @Test("The Mac wire matches the frozen chat-tab-colors-v1 fixture")
    func frozenFixture() throws {
        let fixture = try loadFixture()
        #expect(fixture["capability"] as? String == ChatTabColorContract.capability)
        #expect((fixture["staleAfterSeconds"] as? NSNumber)?.doubleValue == ChatTabColorContract.staleAfterSeconds)
        #expect((fixture["heartbeatSeconds"] as? NSNumber)?.doubleValue == ChatTabColorContract.heartbeatSeconds)
        #expect(fixture["palette"] as? [String] == ChatTabColor.allCases.map(\.rawValue))
        #expect(fixture["unassignedColor"] as? String == "none")

        let publications = try #require(fixture["publications"] as? [String: Any])
        let primary = try #require(publications["primary"] as? [String: Any])
        let primaryData = try JSONSerialization.data(withJSONObject: primary)
        let request = try JSONDecoder().decode(ChatTabColorPublicationRequest.self, from: primaryData)
        #expect(request.serverId == fixture["serverId"] as? String)
        #expect(request.platform == ChatTabColorContract.platform)
        #expect(request.clientName == "Synthetic Primary Companion")
        #expect(request.enabled)
        #expect(request.revision == 7)
        #expect(request.publisherToken.count == 64)
        #expect(ChatTabColorPublisherSecret.isToken(request.publisherToken))
        #expect(request.tabs.count == 4)

        // Re-encoding the fixture entries reproduces explicit nulls and the
        // exact contract key set, so retries stay byte-identical.
        let tabsData = try JSONEncoder().encode(request.tabs)
        let tabsObject = try #require(try JSONSerialization.jsonObject(with: tabsData) as? [[String: Any]])
        #expect(tabsObject.allSatisfy { Set($0.keys) == ["workspaceId", "tabId", "color", "label"] })
        let unassigned = try #require(tabsObject.first { $0["tabId"] as? String == "ws_synthetic_beta:t2" })
        #expect(unassigned["color"] is NSNull)
        #expect(unassigned["label"] is NSNull)
        let assigned = try #require(tabsObject.first { $0["tabId"] as? String == "ws_synthetic_beta:t1" })
        #expect(assigned["color"] as? String == "iris")
        #expect(assigned["label"] as? String == "Synthesé ✦ Planning")

        // The request body exposes exactly the contract fields.
        let requestObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(requestObject.keys) == ["serverId", "publisherToken", "platform", "clientName", "enabled", "revision", "tabs"])

        // Decoding a re-encoded entry round-trips its identity and values.
        let roundTripped = try JSONDecoder().decode([ChatTabColorPublicationTab].self, from: tabsData)
        #expect(roundTripped == request.tabs)
    }

    @Test("Capabilities, publication, and response decoding accept server-shaped JSON")
    func wireDecoding() throws {
        let capabilities = try JSONDecoder().decode(
            ChatTabColorCapabilitiesResponse.self,
            from: Data(#"{"ok":true,"version":1,"serverId":"srv_00000000-0000-4000-8000-000000000000","capabilities":["agent-control-v1","chat-tab-colors-v1"],"chatTabColorStaleAfterSeconds":60}"#.utf8)
        )
        #expect(capabilities.supportsPublication)
        #expect(capabilities.chatTabColorStaleAfterSeconds == 60)

        let older = try JSONDecoder().decode(
            ChatTabColorCapabilitiesResponse.self,
            from: Data(#"{"ok":true,"version":1,"serverId":"srv_00000000-0000-4000-8000-000000000000","capabilities":["agent-control-v1"]}"#.utf8)
        )
        #expect(!older.supportsPublication)
        #expect(older.chatTabColorStaleAfterSeconds == nil)

        let response = try JSONDecoder().decode(
            ChatTabColorPublicationResponse.self,
            from: Data(#"{"ok":true,"serverId":"srv_00000000-0000-4000-8000-000000000000","publication":{"clientId":"ui_11111111-1111-4111-8111-111111111111","platform":"macos","clientName":"Herdr Companion","enabled":true,"revision":12,"tabCount":2,"updatedAt":"2030-01-01T00:00:00Z","lastSeenAt":"2030-01-01T00:00:00Z","stale":false}}"#.utf8)
        )
        #expect(response.ok)
        #expect(response.publication.revision == 12)
        #expect(response.publication.clientId == "ui_11111111-1111-4111-8111-111111111111")
        #expect(response.publication.enabled)
    }

    @Test("Publisher secrets stay in their own 64-hex namespace")
    func publisherSecretNames() throws {
        #expect(ChatTabColorPublisherSecret.account(serverID: "srv_a", clientID: "ui_b")
            == "chat-tab-colors.publisher.srv_a.ui_b")
        #expect(!(ChatTabColorPublisherSecret.account(serverID: "srv_a", clientID: "ui_b")
            == "agent-control.receiver.srv_a.ui_b"))
        #expect(ChatTabColorPublisherSecret.isToken(String(repeating: "a", count: 64)))
        #expect(!ChatTabColorPublisherSecret.isToken(String(repeating: "a", count: 63)))
        #expect(!ChatTabColorPublisherSecret.isToken(String(repeating: "A", count: 64)))
        #expect(!ChatTabColorPublisherSecret.isToken(String(repeating: "g", count: 64)))
    }

    @Test("The Mac identity filter mirrors the companion's tab_identifier contract")
    func identifierContract() {
        #expect(ChatTabColorContract.isValidIdentifier("w1:t1"))
        #expect(ChatTabColorContract.isValidIdentifier("ws_mixed_alpha:t2"))
        #expect(ChatTabColorContract.isValidIdentifier("a:b"))
        #expect(ChatTabColorContract.isValidIdentifier("a.b"))
        #expect(ChatTabColorContract.isValidIdentifier("a_b"))
        #expect(ChatTabColorContract.isValidIdentifier("a-b"))
        #expect(ChatTabColorContract.isValidIdentifier("a"))
        #expect(ChatTabColorContract.isValidIdentifier(String(repeating: "a", count: 256)))
        #expect(!ChatTabColorContract.isValidIdentifier(String(repeating: "a", count: 257)))
        #expect(!ChatTabColorContract.isValidIdentifier(""))
        #expect(!ChatTabColorContract.isValidIdentifier(":leading"))
        #expect(!ChatTabColorContract.isValidIdentifier("has space"))
        #expect(!ChatTabColorContract.isValidIdentifier("bad/id"))
        #expect(!ChatTabColorContract.isValidIdentifier("caf\u{00e9}"))
    }
}

@Suite("Chat tab color live transport", .serialized)
@MainActor
struct ChatTabColorLiveTransportTests {
    @Test("The live transport refuses redirects instead of forwarding the bearer")
    func refusesRedirects() async throws {
        ChatTabColorRedirectURLProtocol.reset()
        let configuration = try #require(ServerConfiguration(
            urlString: "https://synthetic.example.invalid",
            token: "synthetic-bearer"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ChatTabColorRedirectURLProtocol.self]
        let transport = LiveChatTabColorTransport(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )

        do {
            _ = try await transport.capabilities()
            Issue.record("Expected the redirected request to be refused")
        } catch {
            // Expected: the redirect is never followed.
        }

        let requests = ChatTabColorRedirectURLProtocol.recorded()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/api/v1/control/capabilities")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-bearer")
        #expect(requests.allSatisfy { $0.url?.host == "synthetic.example.invalid" })
    }

    @Test("The live transport surfaces the server error envelope")
    func surfacesErrorEnvelope() async throws {
        ChatTabColorErrorEnvelopeURLProtocol.reset()
        let configuration = try #require(ServerConfiguration(
            urlString: "https://synthetic.example.invalid",
            token: "synthetic-bearer"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ChatTabColorErrorEnvelopeURLProtocol.self]
        let transport = LiveChatTabColorTransport(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )
        let request = ChatTabColorPublicationRequest(
            serverId: "srv_00000000-0000-4000-8000-000000000000",
            publisherToken: String(repeating: "a", count: 64),
            platform: ChatTabColorContract.platform,
            clientName: ChatTabColorContract.clientName,
            enabled: true,
            revision: 1,
            tabs: []
        )

        do {
            _ = try await transport.publish(clientId: "ui_11111111-1111-4111-8111-111111111111", request: request)
            Issue.record("Expected the unauthorized response to throw")
        } catch let error as AgentControlCommandError {
            #expect(error.code == "publisher_unauthorized")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func loadFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/chat-tab-colors-v1.json")
    let data = try Data(contentsOf: url)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class ChatTabColorRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recordedRequests = Mutex<[URLRequest]>([])

    static func reset() {
        recordedRequests.withLock { $0 = [] }
    }

    static func recorded() -> [URLRequest] {
        recordedRequests.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.withLock { $0.append(request) }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if request.url?.path == "/api/v1/control/capabilities" {
            let redirectResponse = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://redirected.example.invalid/elsewhere"]
            )!
            let redirected = URLRequest(url: URL(string: "https://redirected.example.invalid/elsewhere")!)
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: redirectResponse)
            return
        }
        // The redirect target answers successfully. Recording a second request
        // here means the bearer was forwarded, which must never happen.
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(
            #"{"ok":true,"version":1,"serverId":"srv_00000000-0000-4000-8000-000000000000","capabilities":["chat-tab-colors-v1"],"chatTabColorStaleAfterSeconds":60}"#.utf8
        ))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ChatTabColorErrorEnvelopeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestCount = Mutex<Int>(0)

    static func reset() {
        requestCount.withLock { $0 = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(
            #"{"ok":false,"error":{"code":"publisher_unauthorized","message":"Publisher credentials are invalid"}}"#.utf8
        ))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
