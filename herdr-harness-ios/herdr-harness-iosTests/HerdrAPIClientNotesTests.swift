import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Shared notes HTTP client", .serialized)
struct HerdrAPIClientNotesTests {
    @Test("Notes are read from the authenticated machine endpoint without a mutation")
    func authenticatedReadContract() async throws {
        NotesURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "notes-test-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NotesURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = HerdrAPIClient(configuration: configuration, session: session)

        let response = try await client.fetchNotes()

        let request = try #require(NotesURLProtocol.recorder.request())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/notes")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer notes-test-token")
        #expect(response.ok)
        #expect(response.revision == 4)
        #expect(response.notes.first?.body == "Agent edited this shared note")
        #expect(response.notes.first?.revision == 3)
        #expect(response.deletedIDs.count == 1)
    }
}

private final class NotesURLProtocol: URLProtocol {
    static let recorder = NotesRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("""
        {"ok":true,"revision":4,"notes":[{
          "id":"11111111-1111-1111-1111-111111111111","title":"Shared note","body":"Agent edited this shared note",
          "color":"lavender","createdAt":1000,"updatedAt":2000,"revision":3,"actions":[],"links":[]
        }],"deletedIDs":["22222222-2222-2222-2222-222222222222"]}
        """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class NotesRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: URLRequest?
    func reset() { lock.withLock { recorded = nil } }
    func record(_ request: URLRequest) { lock.withLock { recorded = request } }
    func request() -> URLRequest? { lock.withLock { recorded } }
}
