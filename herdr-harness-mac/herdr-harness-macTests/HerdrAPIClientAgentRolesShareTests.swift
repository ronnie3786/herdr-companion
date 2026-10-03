import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles sharing client", .serialized)
struct HerdrAPIClientAgentRolesShareTests {
    @Test("The export preview is a GET with preview=1 and a long timeout")
    func preview() async throws {
        let response: [String: Any] = [
            "ok": true, "machineId": "server-desktop", "revision": 7,
            "roles": [["id": "worker", "name": "Worker", "purpose": "worker", "builtin": true, "group": "", "avatar": "review",
                       "allowDelegation": true, "shareable": true, "note": "", "automaticSkills": false,
                       "skills": [["id": "skill_alpha", "name": "Atlas notes", "included": true, "files": 4, "bytes": 18_234, "executable": 1]],
                       "laterField": "ignored"]],
            "warnings": [],
        ]
        ShareURLProtocol.stub.respond(status: 200, json: response)
        let preview = try await makeClient().fetchAgentRolesSharePreview()
        let request = try #require(ShareURLProtocol.stub.request())
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/agent-roles/export")
        #expect(request.query == "preview=1")
        #expect(request.authorization == "Bearer synthetic-token")
        #expect(request.timeout == 120)
        #expect(preview.revision == 7)
        #expect(preview.roles.first?.allowDelegation == true)
        #expect(preview.roles.first?.skills.first?.bytes == 18_234)
        #expect(preview.roles.first?.skills.first?.executable == 1)
    }

    @Test("Exports name the roles and keep the document's unknown keys and exact values")
    func export() async throws {
        let document: [String: Any] = [
            "format": "herdr-agent-roles", "version": 1, "exportedAt": "2026-10-02T21:00:00Z",
            "roles": [["id": "worker", "name": "Wörker ✓", "skillIds": NSNull(), "allowDelegation": false, "laterRoleField": 3]],
            "skills": [], "laterField": ["path": "scripts/run.sh", "flag": true],
        ]
        ShareURLProtocol.stub.respond(status: 200, json: [
            "ok": true, "document": document,
            "summary": ["roles": 1, "skills": 0, "files": 0, "bytes": 0],
            "warnings": ["Worker: the selected skill ‘x’ isn't stored on this computer, so only its name is shared."],
        ])
        let export = try await makeClient().exportAgentRoles(roleIDs: ["worker", "aaaa0000-0000-4000-8000-000000000001"])
        let request = try #require(ShareURLProtocol.stub.request())
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/agent-roles/export")
        #expect(request.query == "roleIds=worker,aaaa0000-0000-4000-8000-000000000001")
        #expect(request.timeout == 120)
        #expect(export.summary == .init(roles: 1, skills: 0, files: 0, bytes: 0))
        #expect(export.warnings.count == 1)
        let text = String(decoding: export.document, as: UTF8.self)
        #expect(text.contains("scripts/run.sh"))
        #expect(!text.contains("scripts\\/run.sh"))
        #expect(text.contains("\n"))
        #expect(text.contains("Wörker ✓"))
        let ordered = try ["\"exportedAt\"", "\"format\"", "\"laterField\"", "\"roles\"", "\"skills\"", "\"version\""]
            .map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(ordered == ordered.sorted())
        let written = try #require(JSONSerialization.jsonObject(with: export.document) as? NSDictionary)
        #expect(written == document as NSDictionary)
        let roles = try #require(written["roles"] as? [[String: Any]])
        #expect(roles.first?["skillIds"] is NSNull)
        #expect(roles.first?["laterRoleField"] as? Int == 3)
    }

    @Test("A response without a roles document is rejected")
    func exportWithoutDocument() async throws {
        ShareURLProtocol.stub.respond(status: 200, json: ["ok": true, "summary": ["roles": 0, "skills": 0, "files": 0, "bytes": 0]])
        await #expect(throws: APIError.self) { try await makeClient().exportAgentRoles(roleIDs: []) }
        ShareURLProtocol.stub.respond(status: 200, json: ["ok": true, "document": ["format": "other", "version": 1, "roles": []]])
        await #expect(throws: APIError.self) { try await makeClient().exportAgentRoles(roleIDs: []) }
    }

    @Test("A blocked export reports the companion's explanation")
    func blockedExport() async throws {
        let message = "‘Security reviewer’ skill ‘deploy’ file scripts/key.txt contains a private key. Remove it or leave this role out."
        ShareURLProtocol.stub.respond(status: 400, json: ["error": ["code": "agent_roles_export_blocked", "message": message]])
        do {
            _ = try await makeClient().exportAgentRoles(roleIDs: ["worker"])
            Issue.record("Expected the export to be blocked")
        } catch let APIError.server(status, received) {
            #expect(status == 400)
            #expect(received == message)
        }
    }

    @Test("Imports send the file byte for byte with the plan fields", arguments: [true, false])
    func importBody(dryRun: Bool) async throws {
        let document = Data("""
            {"format":"herdr-agent-roles","version":1,"roles":[{"id":"worker","laterRoleField":{"z":1,"a":[2,3]}}],
              "skills":[],   "laterField":"scripts/run.sh"}
            """.utf8)
        ShareURLProtocol.stub.respond(status: 200, json: try planResponse(dryRun: dryRun))
        let plan = try await makeClient().importAgentRoles(
            document: document, dryRun: dryRun, expectedRevision: dryRun ? nil : 7,
            planDigest: dryRun ? nil : String(repeating: "d", count: 64),
            roleIDs: dryRun ? nil : ["worker", "aaaa0000-0000-4000-8000-000000000001"],
            replaceRoleIDs: dryRun ? nil : ["worker"], localSkills: ["skill_alpha": String(repeating: "a", count: 64)])
        let request = try #require(ShareURLProtocol.stub.request())
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/agent-roles/import")
        #expect(request.contentType == "application/json")
        #expect(request.timeout == 120)
        let body = try #require(request.body)
        #expect(body.starts(with: Data("{\"document\":".utf8) + document))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["document"] as? NSDictionary)
        let original = try #require(JSONSerialization.jsonObject(with: document) as? NSDictionary)
        #expect(sent == original)
        #expect(json["dryRun"] as? Bool == dryRun)
        #expect(json["localSkills"] as? [String: String] == ["skill_alpha": String(repeating: "a", count: 64)])
        if dryRun {
            #expect(json["expectedRevision"] == nil)
            #expect(json["planDigest"] == nil)
            #expect(json["roleIds"] == nil)
            #expect(json["replaceRoleIds"] == nil)
        } else {
            #expect(json["expectedRevision"] as? Int == 7)
            #expect(json["planDigest"] as? String == String(repeating: "d", count: 64))
            #expect(json["roleIds"] as? [String] == ["worker", "aaaa0000-0000-4000-8000-000000000001"])
            #expect(json["replaceRoleIds"] as? [String] == ["worker"])
        }
        #expect(plan.dryRun == dryRun)
        #expect(plan.roles.first?.role?.systemPrompt == "Prefer small sample changes.")
        #expect(plan.roles.first?.current?.name == "Worker")
        #expect(plan.skills.first?.files.last?.executable == true)
        #expect((plan.overview != nil) == !dryRun)
        #expect(plan.imported?.updated == (dryRun ? nil : 1))
    }

    @Test("Stale or changed plans surface as conflicts for the store to re-plan")
    func importConflict() async throws {
        ShareURLProtocol.stub.respond(status: 409, json: ["error": ["code": "import_plan_changed", "message": "Roles changed."]])
        do {
            _ = try await makeClient().importAgentRoles(document: Data("{}".utf8), dryRun: false, expectedRevision: 7,
                planDigest: "digest", roleIDs: ["worker"], replaceRoleIDs: ["worker"], localSkills: nil)
            Issue.record("Expected a conflict")
        } catch let APIError.server(status, _) {
            #expect(status == 409)
        }
    }

    @Test("Only a JSON object can be spliced into the request")
    func importBodyShape() throws {
        let fields = Data("{\"dryRun\":true}".utf8)
        let body = try HerdrAPIClient.importBody(document: Data("\n {\"a\":1}\n".utf8), fields: fields)
        #expect(String(decoding: body, as: UTF8.self) == "{\"document\":\n {\"a\":1}\n,\"dryRun\":true}")
        #expect(throws: AgentRolesShareFileError.self) {
            try HerdrAPIClient.importBody(document: Data("[1]".utf8), fields: fields)
        }
        #expect(try HerdrAPIClient.importBody(document: Data("{}".utf8), fields: Data("{}".utf8)) == Data("{\"document\":{}}".utf8))
    }

    @Test("Clients from before sharing report that the companion needs an update")
    func defaultRequirements() async {
        let client: any AgentRolesClient = DelayedAgentRolesTestClient()
        do {
            _ = try await client.fetchAgentRolesSharePreview()
            Issue.record("Expected an update prompt")
        } catch let APIError.server(status, message) {
            #expect(status == 426)
            #expect(message == "Update the companion to share roles.")
        } catch { Issue.record("Unexpected \(error)") }
        await #expect(throws: APIError.self) {
            try await client.importAgentRoles(document: Data("{}".utf8), dryRun: true, expectedRevision: nil,
                                              planDigest: nil, roleIDs: nil, replaceRoleIDs: nil, localSkills: [:])
        }
    }

    private func planResponse(dryRun: Bool) throws -> [String: Any] {
        var worker = AgentRoleTestFixtures.roles[2]
        worker.systemPrompt = "Prefer small sample changes."
        var object: [String: Any] = [
            "ok": true, "dryRun": dryRun, "machineId": "server-desktop", "revision": 7,
            "planDigest": String(repeating: "d", count: 64), "exportedAt": "2026-10-02T21:00:00Z",
            "roles": [[
                "id": "worker", "name": "Worker", "purpose": "worker", "builtin": true, "action": "update", "reason": "",
                "selectedByDefault": false,
                "role": try JSONSerialization.jsonObject(with: JSONEncoder().encode(worker)),
                "current": try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentRoleTestFixtures.roles[2])),
                "changes": ["System prompt"], "team": NSNull(),
                "skills": [["id": "skill_bravo", "sourceId": "skill_bravo", "name": "Build compass", "outcome": "included"]],
                "notes": [], "laterField": true,
            ]],
            "skills": [[
                "id": "skill_bravo", "sourceId": "skill_bravo", "name": "Build compass", "description": "Synthetic skill.",
                "outcome": "included",
                "files": [["path": "SKILL.md", "bytes": 1_240, "executable": false],
                          ["path": "scripts/check.sh", "bytes": 300, "executable": true]],
                "bytes": 1_540, "executableFiles": 1, "skillText": "Synthetic skill", "usedBy": ["worker"],
            ]],
            "teams": [], "warnings": [],
        ]
        if !dryRun {
            object["imported"] = ["created": 0, "updated": 1, "unchanged": 0]
            object["overview"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentRoleTestFixtures.shareOverview(revision: 8)))
        }
        return object
    }

    private func makeClient() throws -> HerdrAPIClient {
        let config = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-token"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ShareURLProtocol.self]
        return HerdrAPIClient(configuration: config, session: URLSession(configuration: session))
    }
}

private final class ShareURLProtocol: URLProtocol {
    static let stub = ShareStub()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.stub.record(request)
        let (status, data) = Self.stub.response()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ShareStub: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let contentType: String?
        let timeout: TimeInterval
        let body: Data?
    }
    private let lock = NSLock()
    private var lastRequest: Request?
    private var status = 200
    private var data = Data("{}".utf8)

    func respond(status: Int, json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        lock.withLock {
            self.status = status
            self.data = data
            lastRequest = nil
        }
    }
    func response() -> (Int, Data) { lock.withLock { (status, data) } }
    func request() -> Request? { lock.withLock { lastRequest } }
    func record(_ request: URLRequest) {
        let url = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let recorded = Request(method: request.httpMethod ?? "", path: url?.path ?? "", query: url?.percentEncodedQuery,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            timeout: request.timeoutInterval, body: request.httpBody ?? Self.read(request.httpBodyStream))
        lock.withLock { lastRequest = recorded }
    }
    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
