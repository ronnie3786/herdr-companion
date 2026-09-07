import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Notes client", .serialized)
struct HerdrAPIClientNotesTests {
    @Test("Capacity errors remain retryable instead of becoming deleted-note conflicts")
    func capacityError() async throws {
        NotesAPIURLProtocol.reply.withLock { $0 = #"{"ok":false,"error":{"code":"notes_limit","message":"100 note limit"},"currentNote":null}"# }
        do {
            _ = try await client().createNote(HerdrNote(body: "Keep me locally"))
            Issue.record("Expected capacity error")
        } catch let error as APIError {
            guard case let .server(status, _) = error else { Issue.record("Expected server error"); return }
            #expect(status == 409)
        }
    }
    @Test("Deleted-note conflicts preserve an absent remote snapshot")
    func deletedNote() async throws {
        NotesAPIURLProtocol.reply.withLock { $0 = #"{"ok":false,"error":{"code":"note_deleted","message":"Deleted"},"currentNote":null}"# }
        do {
            _ = try await client().createNote(HerdrNote(body: "Draft"))
            Issue.record("Expected conflict")
        } catch let error as HerdrNotesConflictError {
            #expect(error.currentNote == nil)
        }
    }
    private func client() throws -> HerdrAPIClient {
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [NotesAPIURLProtocol.self]
        return HerdrAPIClient(configuration: configuration, session: URLSession(configuration: session))
    }
}

private final class NotesAPIURLProtocol: URLProtocol {
    static let reply = Mutex("")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil) else { return }
        let body = Self.reply.withLock { $0 }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
