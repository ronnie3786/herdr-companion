import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate project and directory HTTP", .serialized)
struct FirstMateProjectHTTPTests {
    @Test("Reads preserve server identity, scope and opaque folder query values")
    func projectAndDirectoryReads() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let capabilities = try await client.fetchFirstMateCapabilities()
        let active = try await client.fetchFirstMateProjects()
        let all = try await client.fetchFirstMateProjects(scope: .all)
        let firstPage = try await client.fetchDirectories(path: nil, showHidden: false, cursor: nil)
        let path = "/workspace/C++ & sample/#folder?draft=1"
        let cursor = "opaque+page/2=?&keep=1"
        let laterPage = try await client.fetchDirectories(path: path, showHidden: true, cursor: cursor)
        #expect(capabilities.serverID == "synthetic-server")
        #expect(capabilities.supportsProjects)
        #expect(capabilities.supportsDirectoryBrowser)
        #expect(active.serverID == capabilities.serverID)
        #expect(active.projects == all.projects)
        #expect(active.projects.first?.revision == 4)
        #expect(firstPage.homePath == "/home/synthetic")
        #expect(laterPage.entries.first?.resolvedPath == "/workspace/sample-app")
        #expect(laterPage.nextCursor == "next-page")

        let requests = FirstMateProjectURLProtocol.recorder.requests()
        #expect(requests.count == 5)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(try query(requests[1]) == ["scope": "active"])
        #expect(try query(requests[2]) == ["scope": "all"])
        #expect(try query(requests[3]) == ["show_hidden": "false"])
        #expect(try query(requests[4]) == ["show_hidden": "true", "path": path, "cursor": cursor])
        let encodedQuery = try #require(requests[4].url?.absoluteString)
        #expect(encodedQuery.contains("%2B"))
        #expect(!encodedQuery.contains("+"))
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer project-test-token")
            #expect(request.url?.host == "localhost")
        }
    }

    @Test("Project mutations retain request identities, JSON revisions and archive booleans")
    func projectMutations() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let created = try await client.createFirstMateProject(name: "Sample app", cwd: "/workspace/sample-app", requestID: "save-project")
        _ = try await client.createFirstMateProject(name: "Sample app", cwd: "/workspace/sample-app", requestID: "save-project")
        _ = try await client.updateFirstMateProject(id: "fmp:sample", name: "Renamed sample", cwd: "/workspace/renamed-app", expectedRevision: 4, requestID: "edit-project")
        _ = try await client.setFirstMateProjectArchived(id: "fmp:sample", archived: true, expectedRevision: 5, requestID: "archive-project")
        _ = try await client.setFirstMateProjectArchived(id: "fmp:sample", archived: false, expectedRevision: 6, requestID: "restore-project")
        #expect(created.project.id == "fmp:sample")
        let requests = FirstMateProjectURLProtocol.recorder.requests()
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PATCH", "POST", "POST"])
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/v1/first-mate/projects", "/api/v1/first-mate/projects",
            "/api/v1/first-mate/projects/fmp:sample",
            "/api/v1/first-mate/projects/fmp:sample/archive", "/api/v1/first-mate/projects/fmp:sample/archive",
        ])
        let bodies = try requests.map(body)
        #expect(NSDictionary(dictionary: bodies[0]).isEqual(to: bodies[1]))
        #expect(Set(bodies[0].keys) == ["name", "cwd", "request_id"])
        #expect(bodies[0]["request_id"] as? String == "save-project")
        #expect(bodies[2]["expected_revision"] as? Int == 4)
        #expect(bodies[2]["cwd"] as? String == "/workspace/renamed-app")
        #expect(bodies[2]["request_id"] as? String == "edit-project")
        #expect(bodies[3]["archived"] as? Bool == true)
        #expect(bodies[3]["expected_revision"] as? Int == 5)
        #expect(bodies[4]["archived"] as? Bool == false)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer project-test-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    @Test("Project creation sends its prompt once and manual creation retains the legacy body")
    func creationRoutes() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        let prompt = "  Investigate SYNTH-204.\nDo not implement yet.  "
        let linked = try await client.createFirstMateFeature(
            title: "Search investigation", goal: prompt, projectID: "fmp:sample", expectedProjectRevision: 4, requestID: "start-project-session"
        )
        let manual = try await client.createFirstMateFeature(
            title: "Manual investigation", goal: prompt, cwd: "/workspace/manual-app", requestID: "start-manual-session"
        )
        #expect(linked.feature.projectID == "fmp:sample")
        #expect(linked.feature.projectName == "Sample app")
        #expect(linked.feature.projectRevision == 4)
        #expect(linked.feature.cwd == "/workspace/sample-app")
        #expect(manual.feature.projectID == nil)
        #expect(manual.feature.cwd == "/workspace/manual-app")
        let requests = FirstMateProjectURLProtocol.recorder.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/api/v1/first-mate/features" && $0.httpMethod == "POST" })
        let projectBody = try body(requests[0])
        #expect(Set(projectBody.keys) == ["title", "goal", "project_id", "expected_project_revision", "request_id"])
        #expect(projectBody["goal"] as? String == prompt)
        #expect(projectBody["project_id"] as? String == "fmp:sample")
        #expect(projectBody["expected_project_revision"] as? Int == 4)
        #expect(projectBody["request_id"] as? String == "start-project-session")
        let manualBody = try body(requests[1])
        #expect(Set(manualBody.keys) == ["title", "goal", "cwd", "request_id"])
        #expect(manualBody["goal"] as? String == prompt)
        #expect(manualBody["cwd"] as? String == "/workspace/manual-app")
    }

    @Test("Untrusted project IDs cannot alter mutation paths")
    func invalidProjectPaths() async throws {
        let (client, session) = try makeClient()
        defer { session.invalidateAndCancel() }
        for id in ["", ".", "..", "../features", "sample/archive", "sample%2Farchive", "sample?other=1", "sample#fragment"] {
            await #expect(throws: APIError.self) {
                _ = try await client.updateFirstMateProject(id: id, name: "Sample", cwd: "/workspace/sample-app", expectedRevision: 4, requestID: "invalid-edit")
            }
            await #expect(throws: APIError.self) {
                _ = try await client.setFirstMateProjectArchived(id: id, archived: true, expectedRevision: 4, requestID: "invalid-archive")
            }
        }
        #expect(FirstMateProjectURLProtocol.recorder.requests().isEmpty)
    }

    @Test("Authentication and revision failures preserve server status and explanation")
    func mutationErrors() async throws {
        for status in [401, 409, 503] {
            let (client, session) = try makeClient(status: status)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.updateFirstMateProject(id: "fmp:sample", name: "Sample", cwd: "/workspace/sample-app", expectedRevision: 3, requestID: "retryable-edit")
                Issue.record("Expected the server's project mutation error")
            } catch APIError.server(let receivedStatus, let message) {
                #expect(receivedStatus == status)
                #expect(message == "Synthetic project request was rejected")
            }
        }
    }

    private func makeClient(status: Int = 200) throws -> (HerdrAPIClient, URLSession) {
        FirstMateProjectURLProtocol.recorder.reset(status: status)
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "project-test-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstMateProjectURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return (HerdrAPIClient(configuration: configuration, session: session), session)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

private final class FirstMateProjectURLProtocol: URLProtocol {
    static let recorder = FirstMateProjectRequestRecorder()
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
            let project: [String: Any] = [
                "id": "fmp:sample", "name": "Sample app", "cwd": "/workspace/sample-app", "revision": 4,
                "created_at": "2030-01-01T12:00:00Z", "updated_at": "2030-01-02T12:00:00Z", "archived_at": NSNull(),
            ]
            let payload: [String: Any]
            if status != 200 {
                payload = ["ok": false, "error": ["code": "synthetic_rejection", "message": "Synthetic project request was rejected"]]
            } else if url.path.hasSuffix("/capabilities") {
                payload = ["ok": true, "server_id": "synthetic-server", "capabilities": ["first-mate-projects-v1", "directory-browser-v1"]]
            } else if url.path == "/api/v1/directories" {
                payload = [
                    "ok": true, "path": "/workspace", "parent_path": "/", "home_path": "/home/synthetic",
                    "entries": [["name": "Sample alias", "path": "/workspace/Sample alias", "resolved_path": "/workspace/sample-app", "is_symlink": true, "can_open": true]],
                    "next_cursor": "next-page",
                ]
            } else if url.path == "/api/v1/first-mate/projects", request.httpMethod == "GET" {
                payload = ["ok": true, "server_id": "synthetic-server", "projects": [project]]
            } else if url.path == "/api/v1/first-mate/features" {
                let body = try JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any] ?? [:]
                var feature: [String: Any] = [
                    "id": "fmf_sample", "title": body["title"] ?? "Sample", "goal": body["goal"] ?? "Investigate",
                    "cwd": body["cwd"] ?? "/workspace/sample-app", "status": "ready", "revision": 1,
                    "created_at": "2030-01-01T12:00:00Z", "updated_at": "2030-01-01T12:00:00Z",
                ]
                if let projectID = body["project_id"] {
                    feature["project_id"] = projectID
                    feature["project_name"] = "Sample app"
                    feature["project_revision"] = body["expected_project_revision"]
                }
                payload = ["ok": true, "feature": feature]
            } else {
                payload = ["ok": true, "project": project]
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private final class FirstMateProjectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var status = 200
    func reset(status: Int) { lock.withLock { recorded = []; self.status = status } }
    func record(_ request: URLRequest) -> Int { lock.withLock { recorded.append(request); return status } }
    func requests() -> [URLRequest] { lock.withLock { recorded } }
}
