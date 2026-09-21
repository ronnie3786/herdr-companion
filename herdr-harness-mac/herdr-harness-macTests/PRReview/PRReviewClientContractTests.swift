import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("PR Review client contract", .serialized)
struct PRReviewClientContractTests {
    @Test("Path queries preserve names under form decoding")
    func pathQueriesPreserveNamesUnderFormDecoding() async throws {
        let configuration = try #require(ServerConfiguration(
            urlString: "https://example.invalid/synthetic-prefix/",
            token: "synthetic-token"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewPathURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let paths = [
            "Sources/Ordinary.swift",
            "Sources/Example+Live.swift",
            "Sources/Example Live.swift",
            "Sources/100%/Literal%2B.swift",
            "Sources/A&B#C?.swift",
            "Sources/日本語/例.swift",
        ]

        for path in paths {
            PRReviewPathURLProtocol.reset(expectedPath: path)

            let diff = try await client.prReviewDiff(id: "prr_synthetic", path: path)
            let request = try #require(PRReviewPathURLProtocol.recordedRequests().only)
            let rawQuery = try #require(request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            })

            #expect(diff.files.first?.path == path)
            #expect(PRReviewPathURLProtocol.formValues(in: rawQuery)["path"] == path)
            #expect(request.url?.path == "/synthetic-prefix/api/v1/pr-reviews/prr_synthetic/diff")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
            #expect(!rawQuery.contains("+"))
            if path.contains("+") { #expect(rawQuery.contains("%2B")) }
            if path.contains(" ") { #expect(rawQuery.contains("%20")) }
            if path.contains("%") { #expect(rawQuery.contains("%25")) }
        }
    }

    @Test("File text uses the same form-safe path encoding")
    func fileTextUsesFormSafePathEncoding() async throws {
        let path = "Sources/C++/100% real & #? 日本.swift"
        PRReviewPathURLProtocol.reset(expectedPath: path)
        let configuration = try #require(ServerConfiguration(
            urlString: "https://example.invalid/synthetic-prefix",
            token: "synthetic-token"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewPathURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )

        let text = try await client.prReviewFileText(
            id: "prr_synthetic",
            path: path,
            side: .after,
            start: 7,
            end: 11
        )
        let request = try #require(PRReviewPathURLProtocol.recordedRequests().only)
        let rawQuery = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        })
        let values = PRReviewPathURLProtocol.formValues(in: rawQuery)

        #expect(text.path == path)
        #expect(text.text == "synthetic file context")
        #expect(request.url?.path == "/synthetic-prefix/api/v1/pr-reviews/prr_synthetic/file")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(values["path"] == path)
        #expect(values["side"] == "after")
        #expect(values["start"] == "7")
        #expect(values["end"] == "11")
        #expect(!rawQuery.contains("+"))
        #expect(rawQuery.contains("%2B"))
        #expect(rawQuery.contains("%25"))
    }

    @Test("Run output decodes lines and uses the output endpoint")
    func runOutputUsesLinesResponse() async throws {
        PRReviewRunOutputURLProtocol.requests.withLock { $0.removeAll() }
        let configuration = try #require(ServerConfiguration(urlString: "https://example.invalid", token: "synthetic-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PRReviewRunOutputURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))

        let output = try await client.prReviewRunOutput(
            reviewID: "prr_0123456789ab",
            runID: "prun_0123456789ab",
            lines: 17
        )

        let requests = PRReviewRunOutputURLProtocol.requests.withLock { $0 }
        #expect(output == "first fictional line\nsecond fictional line")
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/api/v1/pr-reviews/prr_0123456789ab/runs/prun_0123456789ab/output")
        #expect(URLComponents(url: try #require(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "lines" })?.value == "17")
    }
}

private final class PRReviewPathURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var expectedPath = ""
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static func reset(expectedPath: String) {
        state.withLock {
            $0.expectedPath = expectedPath
            $0.requests.removeAll()
        }
    }

    static func recordedRequests() -> [URLRequest] {
        state.withLock { $0.requests }
    }

    static func formValues(in percentEncodedQuery: String) -> [String: String] {
        var values: [String: String] = [:]
        for field in percentEncodedQuery.split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            else { continue }
            values[name] = value
        }
        return values
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let expectedPath = Self.state.withLock {
            $0.requests.append(request)
            return $0.expectedPath
        }
        let query = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        } ?? ""
        let values = Self.formValues(in: query)
        let pathMatches = values["path"] == expectedPath
        let body: [String: Any]

        if request.url?.path.hasSuffix("/file") == true {
            body = [
                "ok": true,
                "path": pathMatches ? expectedPath : values["path"] ?? "",
                "side": values["side"] ?? "after",
                "start_line": 7,
                "end_line": 11,
                "total_lines": 11,
                "text": pathMatches ? "synthetic file context" : "mismatched path",
            ]
        } else {
            let files: [[String: Any]] = pathMatches ? [[
                "path": expectedPath,
                "old_path": NSNull(),
                "status": "modified",
                "additions": 1,
                "deletions": 0,
                "binary": false,
                "truncated": false,
                "hunks": [],
            ]] : []
            body = [
                "ok": true,
                "review_id": "prr_synthetic",
                "base_sha": "base",
                "head_sha": "head",
                "truncated": false,
                "files": files,
            ]
        }

        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

private final class PRReviewRunOutputURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let body = Data("{\"ok\":true,\"run_id\":\"prun_0123456789ab\",\"lines\":[\"first fictional line\",\"second fictional line\"],\"source\":\"stdout\"}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
