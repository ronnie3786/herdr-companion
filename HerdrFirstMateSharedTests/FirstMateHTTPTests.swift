import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate authenticated HTTP contract", .serialized)
struct FirstMateHTTPTests {
    @Test("Feature direction and controls preserve the caller's request identity")
    func mutations() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        _ = try await client.createFirstMateFeature(
            title: "A clearer review", goal: "Retain every review session", cwd: "/workspace/sample-app", requestID: "create-123"
        )
        _ = try await client.sendFirstMateMessage(featureID: "feature:123", text: "Run the independent reviews", requestID: "direction-456")
        _ = try await client.performFirstMateAction(featureID: "feature:123", action: "pause", requestID: "pause-789")

        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST"])
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/v1/first-mate/features",
            "/api/v1/first-mate/features/feature:123/messages",
            "/api/v1/first-mate/features/feature:123/actions",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-test-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
        let bodies = try requests.map { request -> [String: String] in
            let body = try #require(request.httpBody)
            return try JSONDecoder().decode([String: String].self, from: body)
        }
        #expect(bodies[0] == ["title": "A clearer review", "goal": "Retain every review session", "cwd": "/workspace/sample-app", "request_id": "create-123"])
        #expect(bodies[1] == ["text": "Run the independent reviews", "request_id": "direction-456"])
        #expect(bodies[2] == ["action": "pause", "request_id": "pause-789"])
    }

    @Test("Model settings use the authenticated host and independent settings revision")
    func modelSettings() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let catalog = try await client.fetchFirstMateModels()
        #expect(catalog.models.first?.id == "synthetic/reasoner")
        let settings = FirstMateModelSettings(model: "synthetic/reasoner", thinking: "high", expectedSettingsRevision: 3, requestID: "model-123")
        _ = try await client.setFirstMateModel(featureID: "feature:123", settings: settings)
        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.last?.url?.path == "/api/v1/first-mate/features/feature:123/model-settings")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-test-token")
        let body = try #require(requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["expected_settings_revision"] as? Int == 3)
        #expect(object["model"] as? String == "synthetic/reasoner")
        #expect(object["thinking"] as? String == "high")
        #expect(object["request_id"] as? String == "model-123")
    }

    @Test("Reading a retained session sends the exact identity and earlier-page cursor")
    func savedSessionAndDocuments() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let list = try await client.fetchFirstMateFeatures()
        let snapshot = try await client.fetchFirstMateFeature("feature:123")
        let document = try await client.fetchFirstMateDocument("document:123")
        let transcript = try await client.fetchFirstMateSession("native-session:123", before: 240)

        #expect(list.features.count == 1)
        #expect(snapshot.feature.id == "demo-session-continuity")
        #expect(document.document.id == "document:123")
        #expect(transcript.nativeSessionID == "native-session:123")
        #expect(transcript.nextBefore == 140)
        #expect(transcript.totalMessages == 340)
        #expect(transcript.usage?.costUSD == 0.004)
        #expect(FirstMateUsageFormatting.compactCost(transcript.usage) == "<$0.01")
        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests.count == 4)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-test-token")
            #expect(request.httpBody == nil)
        }
        let request = try #require(requests.last)
        #expect(request.url?.path == "/api/v1/first-mate/sessions/native-session:123")
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query == [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "before", value: "240")])
    }

    @Test("Resource identifiers cannot escape their endpoint collection", arguments: ["", ".", "..", "../notes", "a/b", "a?limit=1", "a#fragment", "%2F", String(repeating: "x", count: 257)])
    func invalidResourceID(_ id: String) async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateDocument(id) }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateSession(id) }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateFeature(id) }
        #expect(FirstMateURLProtocol.recorder.requests().isEmpty)
    }

    @Test("Authentication failures remain visible instead of appearing as an unsupported server")
    @MainActor
    func authenticationFailure() async throws {
        let (client, session) = try makeClient(status: 401)
        defer { session.invalidateAndCancel() }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.error != nil)
        #expect(!store.unsupported)
        #expect(store.features.isEmpty)
        #expect(!store.isDemo)
    }

    private func makeClient(status: Int = 200) throws -> (HerdrAPIClient, URLSession) {
        FirstMateURLProtocol.recorder.reset(status: status)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "first-mate-test-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstMateURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return (HerdrAPIClient(configuration: configuration, session: session), session)
    }
}

private final class FirstMateURLProtocol: URLProtocol {
    static let recorder = FirstMateRequestRecorder()
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
        let status = Self.recorder.record(captured)
        do {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.badURL) }
            let data: Data
            if status != 200 {
                data = Data(#"{"ok":false,"error":{"code":"unauthorized","message":"Authentication required"}}"#.utf8)
            } else if url.path == "/api/v1/first-mate/models" {
                data = Data(#"{"ok":true,"models":[{"id":"synthetic/reasoner","name":"Reasoner","provider":"synthetic","reasoning":true}],"default_model":"synthetic/default","thinking_levels":["off","high"]}"#.utf8)
            } else if url.path.contains("/sessions/") {
                data = Data(#"{"ok":true,"native_session_id":"native-session:123","messages":[{"role":"assistant","text":"Saved review result"}],"next_before":140,"total_messages":340,"usage":{"currency":"USD","cost_usd":0.004,"status":"complete","input_tokens":100,"output_tokens":20,"cache_read_tokens":30,"cache_write_tokens":0,"total_tokens":150,"usage_records":2,"missing_cost_records":0,"session_count":1,"known_cost_sessions":1,"models":[],"updated_at":"2026-09-21T20:00:00Z"}}"#.utf8)
            } else if url.path.contains("/documents/") {
                var document = FirstMateDemo.features(step: 0)[0].documents[0]
                document.id = "document:123"
                data = try JSONSerialization.data(withJSONObject: ["ok": true, "document": JSONSerialization.jsonObject(with: JSONEncoder().encode(document))])
            } else if url.path == "/api/v1/first-mate/features", request.httpMethod == "GET" {
                let feature = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FirstMateDemo.features(step: 0)[0].feature))
                data = try JSONSerialization.data(withJSONObject: ["ok": true, "features": [feature]])
            } else {
                data = try JSONEncoder().encode(FirstMateDemo.features(step: 0)[0])
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private final class FirstMateRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var status = 200
    func reset(status: Int) { lock.withLock { recorded = []; self.status = status } }
    func record(_ request: URLRequest) -> Int { lock.withLock { recorded.append(request); return status } }
    func requests() -> [URLRequest] { lock.withLock { recorded } }
}
