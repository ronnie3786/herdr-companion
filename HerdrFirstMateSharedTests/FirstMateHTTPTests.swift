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
        _ = try await client.setFirstMateArchived(featureID: "feature:123", archived: true, reason: .duplicate, requestID: "archive-101")

        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST", "POST"])
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/v1/first-mate/features",
            "/api/v1/first-mate/features/feature:123/messages",
            "/api/v1/first-mate/features/feature:123/actions",
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
        #expect(bodies[3] == ["action": "archive", "reason": "duplicate", "request_id": "archive-101"])
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

    #if os(macOS)
    @Test("Feature attachments use the bounded authenticated feature route")
    func featureAttachment() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let url = FileManager.default.temporaryDirectory.appending(path: "first-mate-http-synthetic.txt")
        try Data("synthetic attachment".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let response = try await client.uploadFirstMateAttachment(
            featureID: "feature:123",
            fileURL: url,
            contentType: "text/plain"
        )
        #expect(response.attachment?.path == "first-mate:feature:123/attachment-1")
        let request = try #require(FirstMateURLProtocol.recorder.requests().last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/first-mate/features/feature:123/attachments")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-test-token")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["filename"] as? String == url.lastPathComponent)
        #expect(object["content_type"] as? String == "text/plain")
        #expect(Data(base64Encoded: try #require(object["data_base64"] as? String)) == Data("synthetic attachment".utf8))
        #expect(object["workspace_id"] == nil)
        #expect(object["path"] == nil)
    }
    #endif

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

    @Test("Feature list scopes and archive capability use additive authenticated requests")
    func archiveCapabilityAndListScope() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let capabilities = try await client.fetchFirstMateCapabilities()
        _ = try await client.fetchFirstMateFeatures(scope: .all)
        #expect(capabilities.supportsArchive)
        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests[0].url?.path == "/api/v1/first-mate/capabilities")
        #expect(requests[1].url?.path == "/api/v1/first-mate/features")
        #expect(requests[1].url?.query == "view=all")
    }

    @Test("Resource identifiers cannot escape their endpoint collection", arguments: ["", ".", "..", "../notes", "a/b", "a?limit=1", "a#fragment", "%2F", String(repeating: "x", count: 257)])
    func invalidResourceID(_ id: String) async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateDocument(id) }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateSession(id) }
        await #expect(throws: APIError.self) { _ = try await client.fetchFirstMateFeature(id) }
        await #expect(throws: APIError.self) { _ = try await client.setFirstMateLinkVisibility(featureID: "feature:123", linkID: id, hidden: true, requestID: "link-invalid") }
        #expect(FirstMateURLProtocol.recorder.requests().isEmpty)
    }

    #if os(macOS)
    @Test("Feature links post to the authenticated feature route with stable request identity")
    func featureLinks() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let capabilities = try await client.fetchFirstMateCapabilities()
        #expect(capabilities.supportsLinks)
        let saved = try await client.saveFirstMateLink(
            featureID: "feature:123",
            url: "https://github.com/example-org/sample-app/pull/101/files",
            title: "Review the draft",
            kind: nil,
            requestID: "link-save-1"
        )
        #expect(saved.ok)
        #expect(saved.link?.id == "demo-link-pr-101")
        #expect(saved.snapshot.links.count == 3)
        let hidden = try await client.setFirstMateLinkVisibility(
            featureID: "feature:123",
            linkID: "demo-link-pr-101",
            hidden: true,
            requestID: "link-hide-1"
        )
        #expect(hidden.ok)

        let requests = FirstMateURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST"])
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/v1/first-mate/capabilities",
            "/api/v1/first-mate/features/feature:123/links",
            "/api/v1/first-mate/features/feature:123/links/demo-link-pr-101/visibility",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-test-token")
        }
        let saveBody = try #require(requests[1].httpBody)
        let saveObject = try #require(JSONSerialization.jsonObject(with: saveBody) as? [String: Any])
        #expect(saveObject["url"] as? String == "https://github.com/example-org/sample-app/pull/101/files")
        #expect(saveObject["title"] as? String == "Review the draft")
        #expect(saveObject["request_id"] as? String == "link-save-1")
        #expect(saveObject["kind"] == nil)
        #expect(saveObject["provenance"] == nil)
        let visibilityBody = try #require(requests[2].httpBody)
        let visibilityObject = try #require(JSONSerialization.jsonObject(with: visibilityBody) as? [String: Any])
        #expect(visibilityObject["hidden"] as? Bool == true)
        #expect(visibilityObject["request_id"] as? String == "link-hide-1")
        #expect(visibilityObject["provenance"] == nil)
    }
    #endif

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
            } else if url.path == "/api/v1/first-mate/capabilities" {
                data = Data(#"{"ok":true,"capabilities":["first-mate-v1","first-mate-archive-v1","first-mate-links-v1"]}"#.utf8)
            } else if url.path.contains("/links") {
                let snapshot = FirstMateDemo.features(step: 0)[0]
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
                if let link = snapshot.links.first {
                    object["link"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link))
                }
                data = try JSONSerialization.data(withJSONObject: object)
            } else if url.path == "/api/v1/first-mate/models" {
                data = Data(#"{"ok":true,"models":[{"id":"synthetic/reasoner","name":"Reasoner","provider":"synthetic","reasoning":true}],"default_model":"synthetic/default","thinking_levels":["off","high"]}"#.utf8)
            } else if url.path.hasSuffix("/attachments") {
                data = Data(#"{"ok":true,"attachment":{"id":"attachment-1","filename":"first-mate-http-synthetic.txt","originalFilename":"first-mate-http-synthetic.txt","contentType":"text/plain","size":20,"path":"first-mate:feature:123/attachment-1","workspaceId":"first-mate:feature:123","createdAt":"2030-01-01T12:00:00Z"}}"#.utf8)
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
