import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate feedback authenticated HTTP contract", .serialized)
struct FirstMateFeedbackHTTPTests {
    @Test("Category reads and creations use the authenticated exact route")
    func categories() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let list = try await client.fetchFirstMateFeedbackCategories()
        #expect(list.categories.map(\.id) == ["too_long", "unnecessary_message", "incorrect_assumption"])
        #expect(list.categories.map(\.label) == [
            "Longer than it needed to be",
            "Unnecessary message",
            "Incorrect assumption",
        ])
        let created = try await client.createFirstMateFeedbackCategory(
            label: "  Needs   more evidence ",
            requestID: "category-1"
        )
        #expect(created.category.id == "fmc_custom1")
        #expect(created.category.label == "Needs more evidence")

        let requests = FirstMateFeedbackURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/first-mate/feedback-categories",
            "/api/v1/first-mate/feedback-categories",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-feedback-test-token")
        }
        #expect(requests[0].httpBody == nil)
        let body = try #require(requests[1].httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["label", "request_id"])
        #expect(object["label"] as? String == "  Needs   more evidence ")
        #expect(object["request_id"] as? String == "category-1")
    }

    @Test("Feedback saves encode every contract field including an explicit cleared rating")
    func saveEncoding() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let down = FirstMateFeedbackSaveRequest(
            rating: .down,
            categoryIDs: ["too_long", "incorrect_assumption"],
            comment: "Too long.\nKeep it shorter — synthetic ✨",
            expectedRevision: 4,
            requestID: "feedback-down"
        )
        let saved = try await client.saveFirstMateFeedback(
            featureID: "feature:123",
            messageID: "message:456",
            request: down
        )
        #expect(saved.featureID == "feature:123")
        #expect(saved.feedback.messageID == "message:456")
        #expect(saved.feedback.rating == .down)
        #expect(saved.feedback.comment == "Too long.\nKeep it shorter — synthetic ✨")

        let clear = FirstMateFeedbackSaveRequest(
            rating: nil,
            categoryIDs: [],
            comment: "",
            expectedRevision: 5,
            requestID: "feedback-clear"
        )
        _ = try await client.saveFirstMateFeedback(
            featureID: "feature:123",
            messageID: "message:456",
            request: clear
        )

        let requests = FirstMateFeedbackURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/first-mate/features/feature:123/messages/message:456/feedback",
            "/api/v1/first-mate/features/feature:123/messages/message:456/feedback",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-feedback-test-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }

        let firstBody = try #require(requests[0].httpBody)
        let firstObject = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        #expect(Set(firstObject.keys) == ["rating", "category_ids", "comment", "expected_revision", "request_id"])
        #expect(firstObject["rating"] as? String == "down")
        #expect(firstObject["category_ids"] as? [String] == ["too_long", "incorrect_assumption"])
        #expect(firstObject["comment"] as? String == "Too long.\nKeep it shorter — synthetic ✨")
        #expect(firstObject["expected_revision"] as? Int == 4)
        #expect(firstObject["request_id"] as? String == "feedback-down")

        let clearBody = try #require(requests[1].httpBody)
        let clearObject = try #require(JSONSerialization.jsonObject(with: clearBody) as? [String: Any])
        #expect(Set(clearObject.keys) == ["rating", "category_ids", "comment", "expected_revision", "request_id"])
        #expect(clearObject["rating"] is NSNull)
        #expect((clearObject["category_ids"] as? [String])?.isEmpty == true)
        #expect(clearObject["comment"] as? String == "")
        #expect(clearObject["expected_revision"] as? Int == 5)
        #expect(clearObject["request_id"] as? String == "feedback-clear")
    }

    @Test("Feature feedback reads the exact feature and decodes retained provenance")
    func readFeedback() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let response = try await client.fetchFirstMateFeedback(featureID: "feature:123")
        #expect(response.featureID == "feature:123")
        let record = try #require(response.records.first)
        #expect(record.messageID == "message:456")
        #expect(record.featureID == "feature:123")
        #expect(record.rating == .down)
        #expect(record.categoryIDs == ["too_long"])
        #expect(record.comment == "Too long.\nKeep it shorter — synthetic ✨")
        #expect(record.revision == 2)
        #expect(record.provenance.responseText == "A synthetic response")
        #expect(record.provenance.sourceKind == "reply")
        #expect(record.provenance.visitID == "visit-1")
        #expect(record.provenance.featureRevision == 1)
        #expect(record.provenance.coordinatorSessionID == "synthetic-coordinator")
        #expect(record.provenance.sessionProvenance == "verified")
        #expect(record.provenance.inReplyTo == nil)

        let request = try #require(FirstMateFeedbackURLProtocol.recorder.requests().last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/first-mate/features/feature:123/feedback")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer first-mate-feedback-test-token")
        #expect(request.httpBody == nil)
    }

    @Test("Legacy records decode with explicitly unavailable session provenance")
    func legacyProvenance() throws {
        let data = Data(#"{"ok":true,"feature_id":"feature:123","records":[{"message_id":"legacy-1","feature_id":"feature:123","rating":null,"category_ids":[],"comment":"","revision":1,"created_at":"2030-01-01T12:00:00Z","updated_at":"2030-01-01T12:00:00Z","provenance":{"response_text":"Old response","response_created_at":"2029-01-01T12:00:00Z","source_kind":"legacy","in_reply_to":null,"visit_id":null,"feature_revision":null,"coordinator_session_id":null,"session_provenance":"unavailable"}}]}"#.utf8)
        let response = try JSONDecoder().decode(FirstMateFeatureFeedbackResponse.self, from: data)
        let record = try #require(response.records.first)
        #expect(record.rating == nil)
        #expect(record.provenance.sourceKind == "legacy")
        #expect(record.provenance.coordinatorSessionID == nil)
        #expect(record.provenance.sessionProvenance == "unavailable")
    }

    @Test(
        "Escaping feature identifiers never become a request URL",
        arguments: ["../notes", "", "feature/123", "feature?view=all", String(repeating: "x", count: 257)]
    )
    func invalidFeatureIDs(_ featureID: String) async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        await #expect(throws: APIError.self) {
            _ = try await client.fetchFirstMateFeedback(featureID: featureID)
        }
        await #expect(throws: APIError.self) {
            _ = try await client.saveFirstMateFeedback(
                featureID: featureID,
                messageID: "message:456",
                request: invalidSaveRequest
            )
        }
        #expect(FirstMateFeedbackURLProtocol.recorder.requests().isEmpty)
    }

    @Test(
        "Escaping message identifiers never become a request URL",
        arguments: ["a/b", "a?limit=1", "a#fragment", "", ".", "..", String(repeating: "x", count: 257)]
    )
    func invalidMessageIDs(_ messageID: String) async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        await #expect(throws: APIError.self) {
            _ = try await client.saveFirstMateFeedback(
                featureID: "feature:123",
                messageID: messageID,
                request: invalidSaveRequest
            )
        }
        #expect(FirstMateFeedbackURLProtocol.recorder.requests().isEmpty)
    }

    @Test("Authentication failures stay visible and are never missing support")
    @MainActor
    func feedbackAuthenticationFailure() async throws {
        let (client, session) = try makeClient(status: 401)
        defer { session.invalidateAndCancel() }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.feedbackSupported)
        #expect(store.error == nil)
        #expect(!store.unsupported)
        let context = store.operationContext
        await store.loadFeedbackCategories(expectedContext: context)
        #expect(store.feedbackCategoriesError != nil)
        #expect(store.feedbackCategories.isEmpty)
        #expect(!store.unsupported)
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedbackError(for: "demo-session-continuity") != nil)
        #expect(store.feedback(for: "demo-session-continuity", messageID: "demo-mate-0") == nil)
    }

    private var invalidSaveRequest: FirstMateFeedbackSaveRequest {
        FirstMateFeedbackSaveRequest(
            rating: .up,
            categoryIDs: [],
            comment: "",
            expectedRevision: 0,
            requestID: "invalid-path"
        )
    }

    private func makeClient(status: Int = 200) throws -> (HerdrAPIClient, URLSession) {
        FirstMateFeedbackURLProtocol.recorder.reset(feedbackStatus: status)
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "first-mate-feedback-test-token")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstMateFeedbackURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return (HerdrAPIClient(configuration: configuration, session: session), session)
    }
}

private final class FirstMateFeedbackURLProtocol: URLProtocol {
    static let recorder = FirstMateFeedbackRequestRecorder()
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
        let status = Self.recorder.status(for: request)
        do {
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else { throw URLError(.badURL) }
            let data: Data
            if status != 200 {
                data = Data(#"{"ok":false,"error":{"code":"unauthorized","message":"Authentication required"}}"#.utf8)
            } else if url.path == "/api/v1/first-mate/feedback-categories", request.httpMethod == "POST" {
                data = Data(#"{"ok":true,"category":{"id":"fmc_custom1","label":"Needs more evidence","created_at":"2030-01-01T12:00:00Z"}}"#.utf8)
            } else if url.path == "/api/v1/first-mate/feedback-categories" {
                data = Data(#"{"ok":true,"categories":[{"id":"too_long","label":"Longer than it needed to be","created_at":"2030-01-01T12:00:00Z"},{"id":"unnecessary_message","label":"Unnecessary message","created_at":"2030-01-01T12:00:00Z"},{"id":"incorrect_assumption","label":"Incorrect assumption","created_at":"2030-01-01T12:00:00Z"}]}"#.utf8)
            } else if url.path.contains("/messages/"), url.path.hasSuffix("/feedback") {
                data = Data(#"{"ok":true,"feature_id":"feature:123","feedback":{"message_id":"message:456","feature_id":"feature:123","rating":"down","category_ids":["too_long"],"comment":"Too long.\nKeep it shorter — synthetic ✨","revision":2,"created_at":"2030-01-01T12:00:00Z","updated_at":"2030-01-01T12:00:00Z","provenance":{"response_text":"A synthetic response","response_created_at":"2030-01-01T11:00:00Z","source_kind":"reply","in_reply_to":null,"visit_id":"visit-1","feature_revision":1,"coordinator_session_id":"synthetic-coordinator","session_provenance":"verified"}}}"#.utf8)
            } else if url.path.hasSuffix("/feedback") {
                data = Data(#"{"ok":true,"feature_id":"feature:123","records":[{"message_id":"message:456","feature_id":"feature:123","rating":"down","category_ids":["too_long"],"comment":"Too long.\nKeep it shorter — synthetic ✨","revision":2,"created_at":"2030-01-01T12:00:00Z","updated_at":"2030-01-01T12:00:00Z","provenance":{"response_text":"A synthetic response","response_created_at":"2030-01-01T11:00:00Z","source_kind":"reply","in_reply_to":null,"visit_id":"visit-1","feature_revision":1,"coordinator_session_id":"synthetic-coordinator","session_provenance":"verified"}}]}"#.utf8)
            } else if url.path == "/api/v1/first-mate/capabilities" {
                data = Data(#"{"ok":true,"capabilities":["first-mate-v1","first-mate-feedback-v1"]}"#.utf8)
            } else if url.path == "/api/v1/first-mate/features" {
                let features = try JSONEncoder().encode(FirstMateDemo.features(step: 0).map(\.feature))
                let object = try JSONSerialization.jsonObject(with: features)
                data = try JSONSerialization.data(withJSONObject: ["ok": true, "features": object])
            } else if url.path.hasPrefix("/api/v1/first-mate/features/") {
                let snapshot = FirstMateDemo.features(step: 0).first { $0.feature.id == url.lastPathComponent }
                    ?? FirstMateDemo.features(step: 0)[0]
                data = try JSONEncoder().encode(snapshot)
            } else {
                data = Data(#"{"ok":true}"#.utf8)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private final class FirstMateFeedbackRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var feedbackStatus = 200

    func reset(feedbackStatus: Int = 200) {
        lock.withLock {
            recorded = []
            self.feedbackStatus = feedbackStatus
        }
    }

    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }

    func status(for request: URLRequest) -> Int {
        lock.withLock {
            let isFeedbackPath = (request.url?.path.contains("/feedback") ?? false)
                || request.url?.path == "/api/v1/first-mate/feedback-categories"
            return isFeedbackPath ? feedbackStatus : 200
        }
    }

    func requests() -> [URLRequest] { lock.withLock { recorded } }
}
