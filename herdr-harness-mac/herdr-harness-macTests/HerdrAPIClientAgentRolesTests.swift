import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles client", .serialized)
struct HerdrAPIClientAgentRolesTests {
    @Test("Role catalog requests use the saved execution machine and bearer token")
    func catalog() async throws {
        AgentRolesURLProtocol.recorder.reset()
        let overview = try await makeClient().fetchAgentRoles()
        let request = try #require(AgentRolesURLProtocol.recorder.request())
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/agent-roles")
        #expect(request.authorization == "Bearer synthetic-token")
        #expect(overview.capability == "agent-roles-v1")
        #expect(overview.roles.first?.skillIds == nil)
        #expect(overview.roles.last?.skillIds == [])
    }

    @Test("Saving carries the full role, revision and selected package payload")
    func save() async throws {
        AgentRolesURLProtocol.recorder.reset()
        let bundle = AgentRoleSkillBundle(id: "skill_alpha", name: "Atlas notes", description: "Synthetic skill.", source: "personal",
            files: [.init(path: "SKILL.md", content: Data("example".utf8).base64EncodedString(), executable: false)])
        let mutation = AgentRoleMutation(action: "save", expectedRevision: 3,
            role: AgentRoleTestFixtures.roles[1], roleId: nil, skillBundles: [bundle])
        _ = try await makeClient().mutateAgentRoles(mutation)
        let request = try #require(AgentRolesURLProtocol.recorder.request())
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/agent-roles")
        #expect(request.contentType == "application/json")
        let body = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "save")
        #expect(json["expectedRevision"] as? Int == 3)
        let role = try #require(json["role"] as? [String: Any])
        #expect(role["id"] as? String == "second_mate")
        #expect(role["skillIds"] as? [String] == ["skill_alpha"])
        #expect(role["systemPrompt"] as? String == "")
        let bundles = try #require(json["skillBundles"] as? [[String: Any]])
        #expect(bundles.count == 1)
        let files = try #require(bundles.first?["files"] as? [[String: Any]])
        #expect(files.first?["path"] as? String == "SKILL.md")
        #expect(files.first?["content"] as? String == "ZXhhbXBsZQ==")
    }

    @Test("Inherited skills encode explicit null while strict empty lists stay arrays")
    func explicitNull() throws {
        let inherited = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentRoleTestFixtures.roles[0])) as? [String: Any]
        let strict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentRoleTestFixtures.roles[3])) as? [String: Any]
        #expect(inherited?["skillIds"] is NSNull)
        #expect(strict?["skillIds"] as? [String] == [])
    }

    @Test("Deleting identifies only the custom role and its base revision")
    func delete() async throws {
        AgentRolesURLProtocol.recorder.reset()
        let id = "aaaa0000-0000-4000-8000-000000000001"
        _ = try await makeClient().mutateAgentRoles(.init(action: "delete", expectedRevision: 4, role: nil, roleId: id, skillBundles: []))
        let body = try #require(AgentRolesURLProtocol.recorder.request()?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "delete")
        #expect(json["roleId"] as? String == id)
        #expect(json["role"] == nil)
        #expect(json["expectedRevision"] as? Int == 4)
    }

    private func makeClient() throws -> HerdrAPIClient {
        let config = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "synthetic-token"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AgentRolesURLProtocol.self]
        return HerdrAPIClient(configuration: config, session: URLSession(configuration: session))
    }
}

private final class AgentRolesURLProtocol: URLProtocol {
    static let recorder = AgentRolesRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let data = try? JSONEncoder().encode(AgentRoleTestFixtures.overview()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AgentRolesRequestRecorder: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let authorization: String?
        let contentType: String?
        let body: Data?
    }
    private let lock = NSLock()
    private var lastRequest: Request?
    func reset() { lock.withLock { lastRequest = nil } }
    func request() -> Request? { lock.withLock { lastRequest } }
    func record(_ request: URLRequest) {
        lock.withLock {
            lastRequest = Request(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: request.httpBody ?? read(request.httpBodyStream))
        }
    }
    private func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
