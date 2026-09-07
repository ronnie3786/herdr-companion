import Foundation
import Testing
import SwiftUI
@testable import herdr_harness_ios

@Suite("Shared notes HTTP client", .serialized)
struct HerdrAPIClientNotesTests {
    @Test("Editing sends a revision-checked authenticated patch with rich text")
    func updateContract() async throws {
        NotesURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "notes-test-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NotesURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = HerdrAPIClient(configuration: configuration, session: session)
        let response = try await client.fetchNotes()
        let note = try #require(response.notes.first).stamped(machineID: "work")
        var richBody = AttributedString("Updated text")
        richBody.font = .body.bold()
        let saved = try await client.updateNote(note, title: "Updated title", body: richBody)
        let request = try #require(NotesURLProtocol.recorder.request())
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/notes/\(note.rawID.uuidString)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer notes-test-token")
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["expectedRevision"] as? Int == 3)
        let changes = try #require(payload["changes"] as? [String: Any])
        #expect(changes["title"] as? String == "Updated title")
        #expect(changes["body"] as? String == "Updated text")
        #expect(changes["richBody"] != nil)
        #expect(changes["actions"] == nil)
        #expect(saved.machineID == "work")
        #expect(saved.revision == 4)
    }

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
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "PATCH" {
            client?.urlProtocol(self, didLoad: Data("""
            {"ok":true,"note":{"id":"11111111-1111-1111-1111-111111111111","title":"Updated title","body":"Updated text","color":"lavender","createdAt":1000,"updatedAt":2001,"revision":4}}
            """.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
