import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Issue report client", .serialized)
struct IssueReportClientTests {
    private static let submitReply = """
    {"ok": true, "report": {
        "id": "isr_0123456789ab", "kind": "bug", "title": "Crash on launch", "autofix": true,
        "issueNumber": 42, "issueUrl": "https://github.com/owner/repo/issues/42", "repository": "owner/repo",
        "attachments": [{"filename": "shot.png",
                         "url": "https://github.com/owner/repo/releases/download/issue-attachments/isr_0123456789ab-shot.png",
                         "contentType": "image/png", "size": 12}],
        "createdAt": "2026-09-18T12:00:00Z"
    }}
    """

    @Test("Servers without issue-reports-v1 are refused with a 426 before any upload")
    func requiresCapability() async throws {
        IssueReportStubURLProtocol.reset(capabilities: ["pane-retirement-v1", "pi-session-context-v1"])

        do {
            _ = try await client().submitIssueReport(Self.sampleRequest)
            Issue.record("Expected a 426 upgrade error")
        } catch let error as APIError {
            guard case let .server(status, message) = error else {
                Issue.record("Expected a server error, got \(error)")
                return
            }
            #expect(status == 426)
            #expect(message == "Update the companion server to file bug reports and feature requests from the app.")
        }

        #expect(IssueReportStubURLProtocol.recordedRequests().map(\.path) == ["/api/v1"])
    }

    @Test("Submitting sends the exact request keys and decodes the filed record")
    func submits() async throws {
        IssueReportStubURLProtocol.reset(capabilities: ["pane-retirement-v1", "issue-reports-v1"])

        let record = try await client().submitIssueReport(Self.sampleRequest)

        #expect(record.id == "isr_0123456789ab")
        #expect(record.kind == .bug)
        #expect(record.issueNumber == 42)
        #expect(record.issueUrl == "https://github.com/owner/repo/issues/42")
        #expect(record.repository == "owner/repo")
        #expect(record.attachments.map(\.filename) == ["shot.png"])

        let requests = IssueReportStubURLProtocol.recordedRequests()
        #expect(requests.map(\.path) == ["/api/v1", "/api/v1/issue-reports"])
        let submit = try #require(requests.last)
        #expect(submit.method == "POST")
        #expect(submit.contentType == "application/json")
        #expect(submit.authorization == "Bearer test")
        #expect(submit.timeout == 600)

        let object = try #require(JSONSerialization.jsonObject(with: submit.body) as? [String: Any])
        #expect(Set(object.keys) == ["kind", "title", "body", "autofix", "environment", "attachments", "clientReportId"])
        #expect(object["kind"] as? String == "feature")
        #expect(object["title"] as? String == "Add a quiet mode")
        #expect(object["body"] as? String == "  verbatim\n\n## Details 🚀")
        #expect(object["autofix"] as? Bool == false)
        #expect(object["environment"] as? [String: String] == ["client": "herdr-companion-mac"])
        #expect(object["clientReportId"] as? String == "client-report-0123")
        let attachments = try #require(object["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(Set(attachments[0].keys) == ["filename", "contentType", "dataBase64"])
        #expect(attachments[0]["filename"] as? String == "shot.png")
        #expect(attachments[0]["contentType"] as? String == "image/png")
        #expect(attachments[0]["dataBase64"] as? String == "iVBORw0KGgo=")
    }

    @Test("A response that is not ok is an invalid response")
    func rejectsNotOk() async throws {
        IssueReportStubURLProtocol.reset(
            capabilities: ["issue-reports-v1"],
            submitReply: #"{"ok":false,"report":{"id":"isr_1","issueNumber":1,"issueUrl":"https://github.com/owner/repo/issues/1"}}"#
        )

        do {
            _ = try await client().submitIssueReport(Self.sampleRequest)
            Issue.record("Expected an invalid response error")
        } catch let error as APIError {
            guard case .invalidResponse = error else {
                Issue.record("Expected invalidResponse, got \(error)")
                return
            }
        }
    }

    @Test("Server errors on submit keep their status and message")
    func mapsServerErrors() async throws {
        IssueReportStubURLProtocol.reset(
            capabilities: ["issue-reports-v1"],
            submitReply: #"{"ok":false,"error":{"code":"github_failed","message":"gh issue create failed"}}"#,
            submitStatus: 502
        )

        do {
            _ = try await client().submitIssueReport(Self.sampleRequest)
            Issue.record("Expected a 502")
        } catch let error as APIError {
            guard case let .server(status, message) = error else {
                Issue.record("Expected a server error, got \(error)")
                return
            }
            #expect(status == 502)
            #expect(message == "gh issue create failed")
        }
    }

    @Test("Capabilities decode from the dedicated endpoint")
    func capabilities() async throws {
        IssueReportStubURLProtocol.reset(capabilities: ["issue-reports-v1"])

        let capabilities = try await client().issueReportCapabilities()

        #expect(capabilities.available)
        #expect(capabilities.repository == "owner/repo")
        #expect(capabilities.maxAttachments == 6)
        #expect(capabilities.maxAttachmentBytes == 20 * 1024 * 1024)
        #expect(capabilities.maxTotalAttachmentBytes == 40 * 1024 * 1024)
        #expect(capabilities.publicRepository)
        #expect(IssueReportStubURLProtocol.recordedRequests().map(\.path) == ["/api/v1/issue-reports/capabilities"])
        #expect(IssueReportStubURLProtocol.recordedRequests().first?.timeout == 15)
    }

    @Test("Only the issue-report POST gets the long upload timeout")
    func timeoutRule() {
        // Must cover the server's worst case (five sequential `gh` calls at
        // 120 s each); a shorter idle timeout invites a duplicate issue.
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/issue-reports", method: "POST") >= 5 * 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/issue-reports", method: "POST") == 600)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/issue-reports", method: "GET") == 15)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/issue-reports/capabilities", method: "GET") == 15)
    }

    // MARK: - Helpers

    private static let sampleRequest = IssueReportRequest(
        kind: .feature,
        title: "Add a quiet mode",
        body: "  verbatim\n\n## Details 🚀",
        autofix: false,
        environment: ["client": "herdr-companion-mac"],
        attachments: [
            IssueReportAttachmentBody(filename: "shot.png", contentType: "image/png", dataBase64: "iVBORw0KGgo="),
        ],
        clientReportId: "client-report-0123"
    )

    private func client() throws -> HerdrAPIClient {
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [IssueReportStubURLProtocol.self]
        return HerdrAPIClient(configuration: configuration, session: URLSession(configuration: session))
    }
}

/// Serves `/api/v1`, the capabilities endpoint and the submit endpoint from
/// canned replies while recording every request it sees.
private final class IssueReportStubURLProtocol: URLProtocol {
    struct RecordedRequest: Sendable {
        let path: String
        let method: String
        let body: Data
        let contentType: String?
        let authorization: String?
        let timeout: TimeInterval
    }

    private struct State: Sendable {
        var capabilities: [String] = []
        var submitReply = ""
        var submitStatus = 201
        var requests: [RecordedRequest] = []
    }

    private static let state = Mutex(State())

    static func reset(capabilities: [String], submitReply: String? = nil, submitStatus: Int = 201) {
        state.withLock { current in
            current = State(
                capabilities: capabilities,
                submitReply: submitReply ?? IssueReportClientTests.defaultSubmitReply,
                submitStatus: submitStatus,
                requests: []
            )
        }
    }

    static func recordedRequests() -> [RecordedRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let body = Self.readBody(request)
        let recorded = RecordedRequest(
            path: path,
            method: method,
            body: body,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            timeout: request.timeoutInterval
        )
        let (status, reply): (Int, String) = Self.state.withLock { current in
            current.requests.append(recorded)
            switch (method, path) {
            case ("GET", "/api/v1"):
                let list = current.capabilities.map { "\"\($0)\"" }.joined(separator: ",")
                return (200, #"{"ok":true,"capabilities":[\#(list)]}"#)
            case ("GET", "/api/v1/issue-reports/capabilities"):
                return (200, """
                {"ok":true,"available":true,"repository":"owner/repo","reason":null,"maxAttachments":6,
                 "maxAttachmentBytes":20971520,"maxTotalAttachmentBytes":41943040,"attachmentHosting":"release-assets",
                 "publicRepository":true,"labels":{"report":"herdr-app-report","autofix":"herdr-autofix"}}
                """)
            case ("POST", "/api/v1/issue-reports"):
                return (current.submitStatus, current.submitReply)
            default:
                return (404, #"{"ok":false,"error":{"code":"not_found","message":"Not found"}}"#)
            }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols a body stream, not `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension IssueReportClientTests {
    static var defaultSubmitReply: String { submitReply }
}
