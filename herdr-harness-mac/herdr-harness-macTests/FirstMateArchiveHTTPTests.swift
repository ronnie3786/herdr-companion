import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate archive review HTTP", .serialized)
struct FirstMateArchiveHTTPTests {
    @Test("Archive review carries selected IDs, retention booleans, a preview token and pinned log cursors")
    func roundTrip() async throws {
        ArchiveReviewURLProtocol.recorder.reset()
        let config = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-archive-token"))
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [ArchiveReviewURLProtocol.self]
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel() }
        let client = HerdrAPIClient(configuration: config, session: session)

        let preview = try await client.fetchFirstMateArchivePreview(featureID: "feature_sample")
        #expect(preview.ok)
        #expect(preview.preview.token == "preview_example")
        #expect(preview.preview.eligible)
        #expect(preview.preview.resources.first?.estimatedBytes == nil)
        let submitted = FirstMateArchiveRequest(requestID: "review_request", expectedRevision: 7, previewToken: preview.preview.token,
                                               cleanupOptions: .init(resourceIDs: ["resource_cache"], keepDocuments: false, keepChat: true))
        let result = try await client.confirmFirstMateArchive(featureID: "feature_sample", request: submitted)
        #expect(result.archiveID == "archive_original")
        #expect(result.cleanup.id == "archive_original")
        #expect(result.feature.archiveCleanup?.id == "archive_newer")
        let progress = try await client.fetchFirstMateArchiveProgress(featureID: "feature_sample", archiveID: result.archiveID, after: 21)
        #expect(progress.cleanup?.id == result.archiveID)
        #expect(progress.logs.first?.sequence == 22)

        let requests = ArchiveReviewURLProtocol.recorder.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "GET"])
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/v1/first-mate/features/feature_sample/archive-preview",
            "/api/v1/first-mate/features/feature_sample/actions",
            "/api/v1/first-mate/features/feature_sample/archive-progress",
        ])
        let bodyData = try #require(requests[1].httpBody)
        let parsedBody = try JSONSerialization.jsonObject(with: bodyData)
        let body = try #require(parsedBody as? [String: Any])
        #expect(Set(body.keys) == ["action", "request_id", "expected_revision", "preview_token", "cleanup_options"])
        #expect(body["expected_revision"] as? Int == 7)
        #expect(body["preview_token"] as? String == "preview_example")
        let cleanupOptions = try #require(body["cleanup_options"] as? [String: Any])
        #expect(cleanupOptions["resource_ids"] as? [String] == ["resource_cache"])
        #expect(cleanupOptions["keep_documents"] as? Bool == false)
        #expect(cleanupOptions["keep_chat"] as? Bool == true)
        let progressURL = try #require(requests[2].url)
        let query = try #require(URLComponents(url: progressURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["archive_id": "archive_original", "after": "21", "limit": "100"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-archive-token" })
    }
}

private final class ArchiveReviewURLProtocol: URLProtocol {
    static let recorder = ArchiveReviewRequestRecorder()
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
        Self.recorder.append(captured)
        do {
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            let cleanup: [String: Any] = [
                "id": "archive_original", "status": "cancelled", "attempt": 1, "message": "Session unarchived by another client.",
                "history_available": true, "bytes_reclaimed": 0, "removed": 0, "retained": 1, "failed": 0, "updated_at": "2030-01-01T12:00:00Z",
            ]
            let payload: [String: Any]
            if url.path.hasSuffix("/archive-preview") {
                payload = ["ok": true, "preview": [
                    "feature_id": "feature_sample", "feature_revision": 7, "token": "preview_example", "eligible": true,
                    "document_count": 2, "message_count": 10,
                    "resources": [["id": "resource_cache", "kind": "cache", "path": "/workspace/managed/cache", "estimated_bytes": NSNull(),
                                   "can_delete": true, "selected_by_default": true, "reason": "Owned disposable cache."]],
                ]]
            } else if url.path.hasSuffix("/archive-progress") {
                payload = ["ok": true, "archive_id": "archive_original", "cleanup": cleanup, "next_after": NSNull(), "logs": [
                    ["sequence": 22, "kind": "cache", "path": "/workspace/managed/cache", "outcome": "retained",
                     "reason": "User unarchived.", "bytes_reclaimed": 0, "created_at": "2030-01-01T12:00:00Z"],
                ]]
            } else {
                var latestCleanup = cleanup
                latestCleanup["id"] = "archive_newer"
                payload = ["ok": true, "archive_id": "archive_original", "cleanup": cleanup, "feature": [
                    "id": "feature_sample", "title": "Sample archive", "goal": "Complete a synthetic task", "cwd": "/workspace/sample",
                    "status": "completed", "revision": 7, "created_at": "2030-01-01T12:00:00Z", "updated_at": "2030-01-01T12:00:00Z",
                    "archive_cleanup": latestCleanup,
                ]]
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private final class ArchiveReviewRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { values } }
    func reset() { lock.withLock { values = [] } }
    func append(_ request: URLRequest) { lock.withLock { values.append(request) } }
}
