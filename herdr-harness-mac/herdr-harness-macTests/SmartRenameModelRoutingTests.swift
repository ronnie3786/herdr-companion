import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Smart Rename model routing")
@MainActor
struct SmartRenameModelRoutingTests {
    // MARK: - Pure catalog seam

    @Test("An offered preference is sent unchanged with the selected effort")
    func offeredPreferenceIsSentUnchanged() throws {
        let offered = model(provider: "alpha", id: "offered", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: offered.id,
            thinkingLevel: .medium,
            catalog: catalog(models: [offered], defaultModel: identity(offered)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/offered")
        #expect(resolution.thinkingLevel == .medium)
        #expect(resolution.notice == nil)
    }

    @Test("An empty preference uses the declared machine default")
    func emptyPreferenceUsesDeclaredDefault() throws {
        let fallback = model(provider: "alpha", id: "default", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: nil,
            thinkingLevel: .low,
            catalog: catalog(models: [fallback], defaultModel: identity(fallback)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/default")
        #expect(resolution.thinkingLevel == .low)
        #expect(resolution.notice == nil)
    }

    @Test("A blank preference is treated as machine default, not a model")
    func blankPreferenceIsMachineDefault() throws {
        let fallback = model(provider: "alpha", id: "default", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: " \n\t ",
            thinkingLevel: .low,
            catalog: catalog(models: [fallback], defaultModel: identity(fallback)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/default")
        #expect(resolution.notice == nil)
    }

    @Test("An unavailable preference falls back to the machine default with a notice")
    func unavailablePreferenceFallsBackWithNotice() throws {
        let fallback = model(provider: "alpha", id: "default", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: "beta/beta-only",
            thinkingLevel: .high,
            catalog: catalog(models: [fallback], defaultModel: identity(fallback)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/default")
        #expect(resolution.thinkingLevel == .high)
        #expect(resolution.notice?.contains("beta/beta-only") == true)
        #expect(resolution.notice?.contains("Alpha") == true)
    }

    @Test("An omitted declared default lets Pi choose automatically")
    func omittedDefaultLetsPiChoose() throws {
        let offered = model(provider: "alpha", id: "offered", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: nil,
            thinkingLevel: .low,
            catalog: catalog(models: [offered], defaultModel: nil),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == nil)
        #expect(resolution.thinkingLevel == .low)
        #expect(resolution.notice == nil)
    }

    @Test("Unavailable preference plus omitted default also lets Pi choose")
    func unavailablePreferenceWithOmittedDefaultLetsPiChoose() throws {
        let offered = model(provider: "alpha", id: "offered", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: "beta/beta-only",
            thinkingLevel: .medium,
            catalog: catalog(models: [offered], defaultModel: nil),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == nil)
        #expect(resolution.thinkingLevel == .medium)
        #expect(resolution.notice?.contains("beta/beta-only") == true)
    }

    @Test("A declared default missing from the catalog is an actionable configuration error")
    func declaredDefaultMissingFromCatalog() {
        let offered = model(provider: "alpha", id: "offered", reasoning: true)
        let declared = identity(model(provider: "alpha", id: "missing", reasoning: true, name: "Ghost Model"))
        #expect(throws: SmartRenameModelRoutingError.defaultModelUnavailable(machineName: "Alpha", model: "Ghost Model")) {
            try SmartRenameModelRouting.resolveCatalog(
                preference: nil,
                thinkingLevel: .low,
                catalog: catalog(models: [offered], defaultModel: declared),
                machineName: "Alpha"
            )
        }
        #expect(throws: SmartRenameModelRoutingError.defaultModelUnavailable(machineName: "Alpha", model: "Ghost Model")) {
            try SmartRenameModelRouting.resolveCatalog(
                preference: "beta/beta-only",
                thinkingLevel: .low,
                catalog: catalog(models: [offered], defaultModel: declared),
                machineName: "Alpha"
            )
        }
    }

    @Test("An unsuccessful catalog is rejected before any dispatch")
    func unsuccessfulCatalogIsRejected() {
        let offered = model(provider: "alpha", id: "offered", reasoning: true)
        #expect(throws: SmartRenameModelRoutingError.catalogUnavailable(machineName: "Alpha")) {
            try SmartRenameModelRouting.resolveCatalog(
                preference: nil,
                thinkingLevel: .low,
                catalog: catalog(models: [offered], defaultModel: nil, ok: false),
                machineName: "Alpha"
            )
        }
    }

    @Test("An empty catalog is rejected before any dispatch")
    func emptyCatalogIsRejected() {
        #expect(throws: SmartRenameModelRoutingError.catalogEmpty(machineName: "Alpha")) {
            try SmartRenameModelRouting.resolveCatalog(
                preference: nil,
                thinkingLevel: .low,
                catalog: catalog(models: [], defaultModel: nil),
                machineName: "Alpha"
            )
        }
    }

    @Test("A non-reasoning resolved preference forces Off")
    func nonReasoningPreferenceForcesOff() throws {
        let offered = model(provider: "alpha", id: "legacy", reasoning: false)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: offered.id,
            thinkingLevel: .max,
            catalog: catalog(models: [offered], defaultModel: identity(offered)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/legacy")
        #expect(resolution.thinkingLevel == .off)
        #expect(resolution.notice == nil)
    }

    @Test("A non-reasoning fallback default also forces Off")
    func nonReasoningFallbackForcesOff() throws {
        let fallback = model(provider: "alpha", id: "legacy", reasoning: false)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: "beta/beta-only",
            thinkingLevel: .high,
            catalog: catalog(models: [fallback], defaultModel: identity(fallback)),
            machineName: "Alpha"
        )
        #expect(resolution.modelID == "alpha/legacy")
        #expect(resolution.thinkingLevel == .off)
    }

    @Test("Unknown reasoning keeps the selected effort")
    func unknownReasoningKeepsSelectedEffort() throws {
        let offered = model(provider: "alpha", id: "unknown", reasoning: nil)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: offered.id,
            thinkingLevel: .xhigh,
            catalog: catalog(models: [offered], defaultModel: identity(offered)),
            machineName: "Alpha"
        )
        #expect(resolution.thinkingLevel == .xhigh)
    }

    @Test("A reasoning model keeps a selected Off instead of upgrading it")
    func reasoningModelKeepsSelectedOff() throws {
        let offered = model(provider: "alpha", id: "reasoner", reasoning: true)
        let resolution = try SmartRenameModelRouting.resolveCatalog(
            preference: offered.id,
            thinkingLevel: .off,
            catalog: catalog(models: [offered], defaultModel: identity(offered)),
            machineName: "Alpha"
        )
        #expect(resolution.thinkingLevel == .off)
    }

    // MARK: - Async execution-machine resolution

    @Test("The resolver fetches the execution machine's catalog, not the primary machine's")
    func resolverFetchesExecutionMachineCatalog() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var settings = AgentModelSettings.load(from: fixture.defaults)
        settings.quickChatModel = "beta/beta-only"

        let beta = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "beta",
            appModel: fixture.model
        )
        #expect(beta.modelID == "beta/beta-only")
        #expect(beta.thinkingLevel == .low)
        #expect(beta.notice == nil)

        // The same preference is unavailable on alpha, whose own catalog wins
        // over anything the selected source machine displays.
        let alpha = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "alpha",
            appModel: fixture.model
        )
        #expect(alpha.modelID == "alpha/shared")
        #expect(alpha.notice?.contains("beta/beta-only") == true)
    }

    @Test("Empty naming settings inherit the Agent model, then the machine default")
    func emptyNamingSettingsInheritTheAgentModel() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var settings = AgentModelSettings.load(from: fixture.defaults)
        #expect(settings.effectiveSmartRenameModel == nil)

        let automatic = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "alpha",
            appModel: fixture.model
        )
        #expect(automatic.modelID == "alpha/shared")

        settings.quickChatModel = "alpha/alpha-only"
        let inherited = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "alpha",
            appModel: fixture.model
        )
        #expect(inherited.modelID == "alpha/alpha-only")

        settings.smartRenameModel = "beta/beta-only"
        let own = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "beta",
            appModel: fixture.model
        )
        #expect(own.modelID == "beta/beta-only")
    }

    @Test("An unavailable preference is retained in settings while the request falls back")
    func unavailablePreferenceIsRetained() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var settings = AgentModelSettings.load(from: fixture.defaults)
        settings.smartRenameModel = "beta/beta-only"

        let resolution = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "alpha",
            appModel: fixture.model
        )
        #expect(resolution.modelID == "alpha/shared")
        #expect(resolution.notice?.contains("beta/beta-only") == true)
        #expect(settings.smartRenameModel == "beta/beta-only")
        #expect(settings.effectiveSmartRenameModel == "beta/beta-only")
    }

    @Test("A non-reasoning execution-machine model forces Off through the async resolver")
    func asyncNonReasoningModelForcesOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var settings = AgentModelSettings.load(from: fixture.defaults)
        settings.smartRenameModel = "alpha/legacy"
        settings.smartRenameThinkingLevel = .max

        let resolution = try await SmartRenameModelRouting.resolve(
            settings: settings,
            executionMachineID: "alpha",
            appModel: fixture.model
        )
        #expect(resolution.modelID == "alpha/legacy")
        #expect(resolution.thinkingLevel == .off)
    }

    @Test("A catalog fetch failure surfaces an actionable error")
    func catalogFetchFailureSurfacesError() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let settings = AgentModelSettings.load(from: fixture.defaults)

        await #expect(throws: SmartRenameModelRoutingError.catalogUnavailable(machineName: "Gamma")) {
            try await SmartRenameModelRouting.resolve(
                settings: settings,
                executionMachineID: "gamma",
                appModel: fixture.model
            )
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: HerdrAppModel
        let defaults: UserDefaults
        let suite: String
    }

    private func makeFixture() throws -> Fixture {
        let suite = "SmartRenameModelRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let credentials = TestCredentialStore()
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let machines = [
            HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid"),
            HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid"),
            HerdrMachine(id: "gamma", name: "Gamma", urlString: "https://gamma.example.invalid"),
        ]
        model.machines = machines
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SmartRenameRoutingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        model.clientFactory = { configuration in
            HerdrAPIClient(configuration: configuration, session: session)
        }
        for machine in machines {
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
            model.machineStates[machine.id] = .live
        }
        return Fixture(model: model, defaults: defaults, suite: suite)
    }

    private func model(
        provider: String,
        id: String,
        reasoning: Bool?,
        name: String? = nil
    ) -> PiAvailableModel {
        PiAvailableModel(
            provider: provider,
            modelID: id,
            name: name,
            reasoning: reasoning,
            contextWindow: nil
        )
    }

    private func identity(_ model: PiAvailableModel) -> PiModelIdentity {
        PiModelIdentity(provider: model.provider, id: model.modelID, name: model.name)
    }

    private func catalog(
        models: [PiAvailableModel],
        defaultModel: PiModelIdentity?,
        ok: Bool = true
    ) -> AgentModelCatalogResponse {
        AgentModelCatalogResponse(ok: ok, models: models, defaultModel: defaultModel)
    }
}

/// Answers the agent-model catalog route from each machine's own host. Alpha
/// and beta deliberately advertise different models so a resolver that used
/// the primary machine's list would fail the execution-machine tests. Gamma
/// fails the route to exercise the fetch-failure path.
private final class SmartRenameRoutingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response: (status: Int, body: String)
        switch url.host {
        case "alpha.example.invalid":
            response = (200, Self.alphaCatalog)
        case "beta.example.invalid":
            response = (200, Self.betaCatalog)
        case "gamma.example.invalid":
            response = (503, #"{"ok":false,"error":{"code":"synthetic_unavailable","message":"Synthetic catalog failure"}}"#)
        default:
            response = (404, #"{"ok":false,"error":{"code":"not_found","message":"Synthetic route not found"}}"#)
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let alphaCatalog = """
    {
      "ok": true,
      "models": [
        {"provider": "alpha", "id": "alpha-only", "name": "Alpha Only", "reasoning": true, "context_window": 128000},
        {"provider": "alpha", "id": "legacy", "name": "Alpha Legacy", "reasoning": false, "context_window": 32000},
        {"provider": "alpha", "id": "shared", "name": "Shared Model", "reasoning": true, "context_window": 128000}
      ],
      "default": {"provider": "alpha", "id": "shared", "name": "Shared Model"}
    }
    """

    private static let betaCatalog = """
    {
      "ok": true,
      "models": [
        {"provider": "beta", "id": "beta-only", "name": "Beta Only", "reasoning": true, "context_window": 64000}
      ],
      "default": {"provider": "beta", "id": "beta-only", "name": "Beta Only"}
    }
    """
}
