import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Machine sidebar metadata sync", .serialized)
@MainActor
struct MachineSidebarMetadataSyncTests {
    @Test("Explicit refresh uses only the primary authority and preserves paired UUID identities")
    func productionRefreshSyncsByExactOrigin() async throws {
        let machines = [
            HerdrMachine(
                id: UUID().uuidString,
                name: "Locally Paired One",
                urlString: "https://BUILD.example.test:443/",
                role: "unexpected"
            ),
            HerdrMachine(
                id: UUID().uuidString,
                name: "Locally Paired Two",
                urlString: "https://lab.example.test",
                role: nil
            ),
        ]
        MetadataURLProtocol.fixture.configure(
            status: 200,
            body: #"{"ok":true,"machines":[{"id":"private-build-id","name":"Unrelated Server Name","url":"https://build.example.test","role":"node","sidebarLabel":"Build","sidebarOrder":5},{"id":"private-lab-id","name":"Another Server Name","url":"https://LAB.example.test:443/","role":"work","sidebarLabel":"Lab","sidebarOrder":1}]}"#
        )
        let context = try makeModel(machines: machines)
        defer { context.cleanup() }

        await context.model.refresh()

        #expect(context.model.machines.map(\.id) == machines.map(\.id))
        #expect(context.model.machines.map(\.name) == machines.map(\.name))
        #expect(context.model.machines.map(\.urlString) == machines.map(\.urlString))
        #expect(context.model.machines.map(\.role) == machines.map(\.role))
        #expect(context.model.machines.map(\.sidebarLabel) == ["Build", "Lab"])
        #expect(context.model.machines.map(\.sidebarOrder) == [5, 1])
        #expect(SidebarMachineSegmentPresentation.segments(for: context.model.machines).map(\.title) == ["Lab", "Build"])
        #expect(MetadataURLProtocol.fixture.configHosts() == ["build.example.test"])
        #expect(MetadataURLProtocol.fixture.configAuthorizationValues() == ["Bearer primary-token"])

        let persisted = try #require(context.defaults.data(forKey: "herdr.machines"))
        #expect(try JSONDecoder().decode([HerdrMachine].self, from: persisted) == context.model.machines)
    }

    @Test("A successful authoritative roster clears removed and absent metadata")
    func authoritativeRosterClearsStaleValues() async throws {
        let machines = [
            HerdrMachine(
                id: "primary-uuid", name: "Primary", urlString: "https://primary.example.test",
                sidebarLabel: "Old Primary", sidebarOrder: 4
            ),
            HerdrMachine(
                id: "other-uuid", name: "Other", urlString: "https://other.example.test",
                sidebarLabel: "Old Other", sidebarOrder: 8
            ),
        ]
        MetadataURLProtocol.fixture.configure(
            status: 200,
            body: #"{"ok":true,"machines":[{"id":"config-primary","name":"Primary","url":"https://primary.example.test","role":"node"}]}"#
        )
        let context = try makeModel(machines: machines)
        defer { context.cleanup() }

        await context.model.refresh()

        #expect(context.model.machines.map(\.sidebarLabel) == [nil, nil])
        #expect(context.model.machines.map(\.sidebarOrder) == [nil, nil])
    }

    @Test("Unsupported or failed optional endpoint keeps offline cached metadata")
    func oldServerKeepsCachedValuesAndCoreRefreshLive() async throws {
        let machines = [HerdrMachine(
            id: "primary-uuid", name: "Primary", urlString: "https://primary.example.test",
            sidebarLabel: "Cached", sidebarOrder: 2
        )]
        MetadataURLProtocol.fixture.configure(status: 404, body: #"{"error":{"message":"not found"}}"#)
        let context = try makeModel(machines: machines)
        defer { context.cleanup() }

        await context.model.refresh()

        #expect(context.model.machines == machines)
        #expect(context.model.connectionState == .live)
        #expect(context.model.errorMessage == nil)
    }

    @Test("Ambiguous exact origins apply nothing while safe unmatched origins clear")
    func ambiguousAndUnmatchedOrigins() throws {
        let context = try makeModel(machines: [
            HerdrMachine(
                id: "ambiguous", name: "Ambiguous", urlString: "https://duplicate.example.test",
                sidebarLabel: "Cached Duplicate", sidebarOrder: 1
            ),
            HerdrMachine(
                id: "missing", name: "Missing", urlString: "https://missing.example.test",
                sidebarLabel: "Cached Missing", sidebarOrder: 2
            ),
        ])
        defer { context.cleanup() }
        let primary = try #require(context.model.machines.first)
        let response = HerdrMachineConfigurationResponse(ok: true, machines: [
            .init(url: "https://duplicate.example.test", sidebarLabel: "One", sidebarOrder: 3),
            .init(url: "https://DUPLICATE.example.test:443/", sidebarLabel: "Two", sidebarOrder: 4),
        ])

        context.model.applySidebarMetadata(
            response,
            expectedGeneration: context.model.connectionGeneration,
            expectedPrimaryID: primary.id,
            expectedPrimaryURL: primary.urlString
        )

        #expect(context.model.machines[0].sidebarLabel == "Cached Duplicate")
        #expect(context.model.machines[0].sidebarOrder == 1)
        #expect(context.model.machines[1].sidebarLabel == nil)
        #expect(context.model.machines[1].sidebarOrder == nil)
    }

    @Test("Generation primary identity and primary URL guards reject stale results")
    func staleResultsCannotApply() throws {
        let initial = HerdrMachine(
            id: "primary", name: "Primary", urlString: "https://primary.example.test",
            sidebarLabel: "Cached", sidebarOrder: 1
        )
        let context = try makeModel(machines: [initial])
        defer { context.cleanup() }
        let response = HerdrMachineConfigurationResponse(ok: true, machines: [
            .init(url: initial.urlString, sidebarLabel: "Fresh", sidebarOrder: 9),
        ])
        let generation = context.model.connectionGeneration

        context.model.connectionGeneration += 1
        context.model.applySidebarMetadata(
            response,
            expectedGeneration: generation,
            expectedPrimaryID: initial.id,
            expectedPrimaryURL: initial.urlString
        )
        #expect(context.model.machines[0].sidebarLabel == "Cached")

        context.model.connectionGeneration = generation
        context.model.machines[0].urlString = "https://changed.example.test"
        context.model.applySidebarMetadata(
            response,
            expectedGeneration: generation,
            expectedPrimaryID: initial.id,
            expectedPrimaryURL: initial.urlString
        )
        #expect(context.model.machines[0].sidebarLabel == "Cached")

        context.model.machines = [
            HerdrMachine(id: "new-primary", name: "New", urlString: "https://new.example.test"),
            initial,
        ]
        context.model.applySidebarMetadata(
            response,
            expectedGeneration: generation,
            expectedPrimaryID: initial.id,
            expectedPrimaryURL: initial.urlString
        )
        #expect(context.model.machines[1].sidebarLabel == "Cached")
    }

    @Test("Malformed remote optional fields decode as absent rather than failing the roster")
    func malformedOptionalPresentationIsIgnored() async throws {
        MetadataURLProtocol.fixture.configure(
            status: 200,
            body: #"{"ok":true,"machines":[{"url":"https://primary.example.test","sidebarLabel":"Line\nbreak","sidebarOrder":true},{"url":"https://other.example.test","sidebarLabel":17,"sidebarOrder":2147483648}]}"#
        )
        let configuration = try #require(
            ServerConfiguration(urlString: "https://primary.example.test", token: "test-token")
        )
        let client = HerdrAPIClient(configuration: configuration, session: metadataSession())

        let response = try await client.fetchMachineConfiguration()

        #expect(response.machines.count == 2)
        #expect(response.machines.allSatisfy { $0.sidebarLabel == nil && $0.sidebarOrder == nil })
    }

    @Test("Origin normalization accepts only exact HTTP(S) origins")
    func originNormalization() {
        #expect(HerdrMachine.normalizedOrigin("HTTPS://Example.TEST:443/") == "https://example.test")
        #expect(HerdrMachine.normalizedOrigin("http://Example.TEST:80") == "http://example.test")
        #expect(HerdrMachine.normalizedOrigin("https://example.test:8443/") == "https://example.test:8443")
        #expect(HerdrMachine.normalizedOrigin("https://user@example.test") == nil)
        #expect(HerdrMachine.normalizedOrigin("https://example.test/path") == nil)
        #expect(HerdrMachine.normalizedOrigin("https://example.test?query=1") == nil)
        #expect(HerdrMachine.normalizedOrigin("https://example.test:not-a-port") == nil)
        #expect(HerdrMachine.normalizedOrigin("file:///tmp/example") == nil)
    }

    private func makeModel(machines: [HerdrMachine]) throws -> ModelContext {
        let suiteName = "MachineSidebarMetadataSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(try JSONEncoder().encode(machines), forKey: "herdr.machines")
        defaults.set(true, forKey: "herdr.completedSetup")
        defaults.set(false, forKey: "herdr.demoMode")
        let credentials = TestCredentialStore()
        for (index, machine) in machines.enumerated() {
            credentials.values["api-token.\(machine.id)"] = index == 0 ? "primary-token" : "secondary-token"
        }
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: [],
            userDefaults: defaults,
            configuredMachines: []
        )
        let session = metadataSession()
        model.clientFactory = { HerdrAPIClient(configuration: $0, session: session) }
        for machine in model.machines {
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        }
        return ModelContext(model: model, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private struct ModelContext {
    let model: HerdrAppModel
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        MetadataURLProtocol.fixture.configure(status: 200, body: #"{"ok":true,"machines":[]}"#)
    }
}

private func metadataSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MetadataURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class MetadataURLProtocol: URLProtocol {
    static let fixture = MetadataHTTPFixture()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.fixture.reply(for: request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MetadataHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var metadataStatus = 200
    private var metadataData = Data(#"{"ok":true,"machines":[]}"#.utf8)
    private var recordedConfigHosts: [String] = []
    private var recordedAuthorization: [String] = []

    func configure(status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        metadataStatus = status
        metadataData = Data(body.utf8)
        recordedConfigHosts = []
        recordedAuthorization = []
    }

    func reply(for request: URLRequest) -> (status: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch request.url?.path {
        case "/api/v1/config/machines":
            recordedConfigHosts.append(request.url?.host ?? "")
            recordedAuthorization.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (metadataStatus, metadataData)
        case "/api/v1/result-artifacts":
            return (200, Data(#"{"ok":true,"artifacts":[]}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"workspaces":[],"alerts":[],"starredPaneIds":[]}"#.utf8))
        }
    }

    func configHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedConfigHosts
    }

    func configAuthorizationValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAuthorization
    }
}
