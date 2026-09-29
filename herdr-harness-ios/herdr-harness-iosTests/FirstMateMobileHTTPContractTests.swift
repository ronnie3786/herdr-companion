import Foundation
import Synchronization
import Testing
@testable import herdr_harness_ios

@Suite("Mobile First Mate protocol witnesses", .serialized)
struct FirstMateMobileHTTPContractTests {
    private func makeClient(status: Int = 200, body: Data) throws -> (any FirstMateClient, URLSession) {
        MobileFirstMateHTTPProbe.state.withLock { $0 = .init(status: status, body: body) }
        let configuration = try #require(ServerConfiguration(urlString: "https://phase-one.example.invalid:9443", token: "synthetic-owner-token"))
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [MobileFirstMateHTTPProbe.self]
        let session = URLSession(configuration: options)
        return (HerdrAPIClient(configuration: configuration, session: session), session)
    }

    private var requests: [URLRequest] { MobileFirstMateHTTPProbe.state.withLock { $0.requests } }

    @Test("Lead fetch/ensure dispatch through the protocol and retain optional display metadata")
    func leadWitnesses() async throws {
        let feature = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FirstMateDemo.chatWindowLead().feature))
        for metadata: Any in [NSNull(), ["id": "server-local-id", "name": "Same display name"]] {
            let body = try JSONSerialization.data(withJSONObject: ["ok": true, "lead": [
                "feature": feature, "unread": true, "working_on_reply": false, "machine": metadata,
            ]])
            let (client, session) = try makeClient(body: body)
            defer { session.invalidateAndCancel() }
            let fetched = try await client.fetchFirstMateLead()
            let ensured = try await client.ensureFirstMateLead(requestID: "ensure-on-owner")
            #expect(fetched.lead?.feature.isLead == true)
            #expect(ensured.lead?.machine?.id == (metadata is NSNull ? nil : "server-local-id"))
            #expect(requests.map(\.httpMethod) == ["GET", "POST"])
            #expect(requests.map(\.timeoutInterval) == [15, 86_400])
            #expect(requests.allSatisfy { $0.url?.host == "phase-one.example.invalid" && $0.url?.port == 9443 })
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-owner-token" })
            let object = try JSONDecoder().decode([String: String].self, from: #require(requests.last?.httpBody))
            #expect(object == ["request_id": "ensure-on-owner"])
        }
        let (empty, session) = try makeClient(body: Data(#"{"ok":true,"lead":null}"#.utf8))
        defer { session.invalidateAndCancel() }
        #expect(try await empty.fetchFirstMateLead().lead == nil)
        let absent = try JSONSerialization.data(withJSONObject: ["feature": feature, "unread": false, "working_on_reply": false])
        #expect(try JSONDecoder().decode(FirstMateLeadSummary.self, from: absent).machine == nil)
    }

    @Test("Journal and frozen lead context are concrete protocol witnesses")
    func snapshotAndContextWitnesses() async throws {
        let snapshot = FirstMateDemo.chatWindowLead()
        let (client, session) = try makeClient(body: JSONEncoder().encode(snapshot))
        defer { session.invalidateAndCancel() }
        _ = try await client.fetchFirstMateFeature(snapshot.feature.id, journalEventsOnly: true)
        _ = try await client.fetchFirstMateFeature(snapshot.feature.id, journalEventsOnly: false)
        let context = FirstMateLeadContext(machines: [.init(name: "Synthetic remote", features: [
            .init(label: "Receipts", title: nil, status: "blocked", step: "QA", now: nil, unread: true, latest: nil),
        ], offline: true)])
        _ = try await client.sendFirstMateMessage(featureID: snapshot.feature.id, text: "Review this", requestID: "frozen-request", context: context)
        #expect(requests[0].url?.query == "events=journal")
        #expect(requests[1].url?.query == nil)
        #expect(requests.map(\.timeoutInterval) == [15, 15, 86_400])
        let body = try #require(requests.last?.httpBody)
        struct Sent: Decodable { let text: String; let request_id: String; let context: FirstMateLeadContext }
        let sent = try JSONDecoder().decode(Sent.self, from: body)
        #expect(sent.text == "Review this" && sent.request_id == "frozen-request")
        #expect(sent.context == context)
    }

    @Test("Attachment casing stays compatible and the protocol upload uses its 90 second exception")
    func attachmentWitness() async throws {
        let response = Data(#"{"ok":true,"attachment":{"id":"a","filename":"sample.txt","originalFilename":"Sample.txt","contentType":"text/plain","size":9,"path":"first-mate:feature/a","workspaceId":"first-mate:feature","createdAt":"2030-01-01"}}"#.utf8)
        let (client, session) = try makeClient(body: response)
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appending(path: "synthetic-\(UUID()).txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let upload = try await client.uploadFirstMateAttachment(featureID: "feature", fileURL: file, contentType: "text/plain")
        #expect(upload.attachment?.originalFilename == "Sample.txt")
        let request = try #require(requests.first)
        #expect(request.timeoutInterval == 90)
        #expect(request.url?.path == "/api/v1/first-mate/features/feature/attachments")
        let body = try JSONDecoder().decode(WorkspaceAttachmentBody.self, from: #require(request.httpBody))
        #expect(Data(base64Encoded: body.dataBase64) == Data("synthetic".utf8))
        let snake = try JSONEncoder().encode(#require(upload.attachment))
        let roundTrip = try JSONDecoder().decode(UploadedAttachment.self, from: snake)
        #expect(roundTrip == upload.attachment)
        let encoded = try #require(JSONSerialization.jsonObject(with: snake) as? [String: Any])
        #expect(encoded["original_filename"] as? String == "Sample.txt")
        #expect(encoded["originalFilename"] == nil)
    }

    @Test("Voice dispatch stays on the captured host with the 120 second budget")
    func voiceWitness() async throws {
        let (client, session) = try makeClient(body: Data(#"{"ok":true,"text":"Synthetic dictation","backend":"synthetic","language":"en"}"#.utf8))
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appending(path: "synthetic-\(UUID()).wav")
        var audio = Data("RIFF".utf8)
        audio.append(contentsOf: [38, 0, 0, 0])
        audio.append(Data("WAVEfmt ".utf8))
        audio.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])
        audio.append(Data("data".utf8))
        audio.append(contentsOf: [2, 0, 0, 0, 0, 0])
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await client.transcribeFirstMateVoice(fileURL: file).text == "Synthetic dictation")
        let request = try #require(requests.first)
        #expect(request.url?.path == "/api/v1/voice/transcriptions")
        #expect(request.url?.host == "phase-one.example.invalid" && request.timeoutInterval == 120)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-owner-token")
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(body["mime_type"] == "audio/wav")
        #expect(Data(base64Encoded: body["data_base64"] ?? "") == audio)
    }

    @Test("Server codes preserve two-value status catches and missing-code compatibility", arguments: [401, 404, 409, 501, 503])
    func structuredErrors(status: Int) async throws {
        for code: String? in ["coordinator_busy", nil] {
            var error = ["message": "Synthetic refusal"]
            error["code"] = code
            let (client, session) = try makeClient(status: status, body: JSONSerialization.data(withJSONObject: ["error": error]))
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.fetchFirstMateLead()
                Issue.record("Expected a server error")
            } catch let failure as APIError {
                guard case .server(let actualStatus, let message) = failure else {
                    Issue.record("The existing two-value server catch must match"); return
                }
                #expect(actualStatus == status)
                #expect(message.text == "Synthetic refusal")
                #expect(failure.serverCode == code)
                #expect(failure.localizedDescription == "Synthetic refusal")
            }
        }
    }

    @Test("First Mate timeout policy leaves reads and other flows bounded")
    func timeoutMatrix() {
        for suffix in ["lead", "features", "features/f/messages", "features/f/actions", "features/f/model-settings", "features/f/read", "features/f/links"] {
            #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/" + suffix, method: "POST") == 86_400)
            #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/" + suffix, method: "GET") == 15)
        }
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/features/f/attachments", method: "POST") == 90)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/features/f/attachments", method: "GET") == 15)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/features/events", method: "GET") == 15)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/voice/transcriptions", method: "POST") == 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w/attachments", method: "POST") == 90)
    }
}

private final class MobileFirstMateHTTPProbe: URLProtocol {
    struct State: Sendable {
        var status = 200
        var body = Data()
        var requests: [URLRequest] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let answer = Self.state.withLock { state in
            state.requests.append(captured)
            return (state.status, state.body)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}
