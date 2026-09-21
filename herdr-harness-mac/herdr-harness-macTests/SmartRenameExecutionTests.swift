import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

/// Exercises the real headless naming runner against synthetic HTTP responses.
/// These prove the exact dispatch values and that an advertised model which
/// fails to start or run never mutates the pane, with exactly one attempt.
// The URLProtocol fixture is process-wide, so serialize the suite.
@Suite("Smart Rename live execution", .serialized)
@MainActor
struct SmartRenameExecutionTests {
    @Test("The live naming run sends the exact model, effort, system prompt, and context")
    func liveRunSendsExactRequestValues() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        await fixture.model.smartRename(fixture.pane, runner: HerdrLiveNoteAIRunner())

        let bodies = SmartRenameExecutionURLProtocol.startBodies()
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Ask is the server default, so the client intentionally omits `mode`.
        #expect(json["mode"] == nil)
        #expect(json["model"] as? String == "synthetic/naming")
        #expect(json["thinkingLevel"] as? String == "low")
        #expect(
            json["systemPrompt"] as? String
                == "You name conversations. Use only supplied text. Never call tools. Return only the requested JSON object."
        )
        let prompt = try #require(json["prompt"] as? String)
        #expect(prompt.contains("Rename this synthetic conversation"))
        #expect(prompt.contains("untrusted"))
        #expect(json["continueFromRunId"] == nil)
        #expect(json["cwd"] == nil)
        #expect(json["attachments"] == nil)

        let counts = SmartRenameExecutionURLProtocol.counts()
        #expect(counts.starts == 1)
        #expect(counts.catalogs == 1)
        #expect(counts.prompts == 1)
        #expect(counts.renames == 1)
        #expect(SmartRenameExecutionURLProtocol.renameLabel() == "Synthetic Execution Title")
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Synthetic Execution Title")
        #expect(fixture.model.toastMessage == "Pane renamed")
    }

    @Test("A shell pane without a Pi session is named from terminal output through the live runner")
    func liveRunnerNamesShellPaneFromTerminalOutput() async throws {
        var configuration = SmartRenameExecutionFixture()
        configuration.paneSessionID = nil
        configuration.snapshotBody = nil
        configuration.outputText = "\u{1B}[32m$ deploy synthetic\u{1B}[0m\nrelease complete"
        let fixture = try makeFixture(configuration)
        defer { fixture.tearDown() }

        await fixture.model.smartRename(fixture.pane, runner: HerdrLiveNoteAIRunner())

        let body = try #require(SmartRenameExecutionURLProtocol.startBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let prompt = try #require(json["prompt"] as? String)
        #expect(prompt.contains("deploy synthetic"))
        #expect(prompt.contains("release complete"))
        #expect(!prompt.contains("\u{1B}"))

        let counts = SmartRenameExecutionURLProtocol.counts()
        #expect(counts.starts == 1)
        #expect(counts.renames == 1)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Synthetic Execution Title")
    }

    @Test("An advertised model that fails to start preserves the title and reports the selection")
    func advertisedModelStartFailurePreservesTitle() async throws {
        var configuration = SmartRenameExecutionFixture()
        configuration.startBehavior = .failStart
        let fixture = try makeFixture(configuration)
        defer { fixture.tearDown() }

        await fixture.model.smartRename(fixture.pane, runner: HerdrLiveNoteAIRunner())

        let counts = SmartRenameExecutionURLProtocol.counts()
        #expect(counts.starts == 1)
        #expect(counts.renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        let toast = try #require(fixture.model.toastMessage)
        #expect(toast.hasPrefix("Smart Rename failed"))
        #expect(toast.contains("synthetic/naming"))
        #expect(toast.contains("Low"))
        #expect(toast.contains("Execution Mac"))
        #expect(toast.contains("Synthetic start failure"))
        #expect(toast.contains("Settings"))
    }

    @Test("A failed run carrying partial title text never mutates the pane and reports once")
    func advertisedModelRunFailureCarriesNoPartialTitle() async throws {
        var configuration = SmartRenameExecutionFixture()
        configuration.startBehavior = .failRun
        let fixture = try makeFixture(configuration)
        defer { fixture.tearDown() }

        await fixture.model.smartRename(fixture.pane, runner: HerdrLiveNoteAIRunner())

        let counts = SmartRenameExecutionURLProtocol.counts()
        #expect(counts.starts == 1)
        #expect(counts.fetches >= 1)
        #expect(counts.renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        let toast = try #require(fixture.model.toastMessage)
        #expect(toast.hasPrefix("Smart Rename failed"))
        #expect(toast.contains("synthetic/naming"))
        #expect(toast.contains("Execution Mac"))
        #expect(toast.contains("Synthetic provider failure"))
        #expect(toast.contains("Settings"))
        #expect(!toast.contains("Partial synthetic title"))
    }

    @Test("A missing naming selection dispatches no run and no replacement model")
    func missingSelectionDispatchesNothing() async throws {
        let fixture = try makeFixture(preference: "ghost/model")
        defer { fixture.tearDown() }

        await fixture.model.smartRename(fixture.pane, runner: HerdrLiveNoteAIRunner())

        let counts = SmartRenameExecutionURLProtocol.counts()
        #expect(counts.starts == 0)
        #expect(counts.fetches == 0)
        #expect(counts.catalogs == 1)
        #expect(counts.renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        let toast = try #require(fixture.model.toastMessage)
        #expect(toast.hasPrefix("Smart Rename failed"))
        #expect(toast.contains("ghost/model"))
        #expect(toast.contains("Execution Mac"))
        #expect(toast.contains("Settings"))
        #expect(fixture.defaults.string(forKey: AgentModelSettings.quickChatModelKey) == "ghost/model")
    }

    // MARK: - Fixtures

    @MainActor
    private struct Fixture {
        let model: HerdrAppModel
        let pane: HerdrPane
        let defaults: UserDefaults
        let suite: String

        func tearDown() {
            model.clientFactory = { HerdrAPIClient(configuration: $0) }
            defaults.removePersistentDomain(forName: suite)
            SmartRenameExecutionURLProtocol.reset()
        }
    }

    private func makeFixture(
        _ configuration: SmartRenameExecutionFixture = SmartRenameExecutionFixture(),
        preference: String? = nil
    ) throws -> Fixture {
        SmartRenameExecutionURLProtocol.configure(configuration)
        let suite = "SmartRenameExecutionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let preference {
            defaults.set(preference, forKey: AgentModelSettings.quickChatModelKey)
        }
        let credentials = TestCredentialStore()
        let machine = HerdrMachine(
            id: "execution",
            name: "Execution Mac",
            urlString: "http://127.0.0.1:9477"
        )
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SmartRenameExecutionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        model.machines = [machine]
        model.clientFactory = { configuration in
            HerdrAPIClient(configuration: configuration, session: session)
        }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let semantic: PiSemanticCapability? = configuration.paneSessionID.flatMap { sessionID in
            try? JSONDecoder().decode(
                PiSemanticCapability.self,
                from: Data(
                    "{\"available\":true,\"connected\":true,\"protocol_version\":1,\"session_id\":\"\(sessionID)\"}".utf8
                )
            )
        }
        let pane = HerdrPane(
            paneID: "p1",
            terminalID: "term1",
            workspaceID: "w1",
            tabID: "t1",
            focused: true,
            agentStatus: .idle,
            revision: 1,
            cwd: nil,
            foregroundCWD: nil,
            label: "Original title",
            title: nil,
            agent: configuration.paneSessionID == nil ? "zsh" : "pi",
            displayAgent: configuration.paneSessionID == nil ? "Terminal" : "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil,
            piSemantic: semantic
        ).stamped(machineID: machine.id)
        let tab = HerdrTab(
            tabID: "t1",
            workspaceID: "w1",
            number: 1,
            label: "Synthetic tab",
            focused: true,
            paneCount: 1,
            agentStatus: .idle
        ).stamped(machineID: machine.id)
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1",
            number: 1,
            label: "Synthetic workspace",
            focused: true,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "t1",
            agentStatus: .idle,
            tabs: [tab],
            panes: [pane]
        ).stamped(machineID: machine.id)]
        return Fixture(model: model, pane: pane, defaults: defaults, suite: suite)
    }
}

private struct SmartRenameExecutionFixture: Sendable {
    enum StartBehavior: Sendable {
        case complete(String)
        case failStart
        case failRun
    }

    var paneSessionID: String? = "synthetic-session"
    var snapshotBody: String? = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[{"type":"message","id":"a","message":{"role":"user","content":[{"type":"text","text":"Rename this synthetic conversation"}]}}]}"#
    var outputText: String? = nil
    var catalogBody: String = Self.defaultCatalog
    var startBehavior: StartBehavior = .complete(#"{"title":"Synthetic Execution Title"}"#)
    var promptsAvailable = true

    static let defaultCatalog = #"{"ok":true,"models":[{"provider":"synthetic","id":"naming","name":"Synthetic Naming","reasoning":true,"context_window":64000}],"default":{"provider":"synthetic","id":"naming","name":"Synthetic Naming"}}"#
}

/// Answers the naming catalog, prompt-defaults probe, headless start/poll
/// routes, snapshot/output context, rename mutation, and refresh from one
/// synthetic server.
private final class SmartRenameExecutionURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var fixture = SmartRenameExecutionFixture()
        var starts = 0
        var catalogs = 0
        var prompts = 0
        var fetches = 0
        var renames = 0
        var renamedLabel: String?
        var startBodies: [Data] = []
    }

    private static let state = Mutex(State())

    static func configure(_ fixture: SmartRenameExecutionFixture) {
        state.withLock { $0 = State(fixture: fixture) }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func counts() -> (starts: Int, catalogs: Int, prompts: Int, fetches: Int, renames: Int) {
        state.withLock { ($0.starts, $0.catalogs, $0.prompts, $0.fetches, $0.renames) }
    }

    static func startBodies() -> [Data] {
        state.withLock { $0.startBodies }
    }

    static func renameLabel() -> String? {
        state.withLock { $0.renamedLabel }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let body = requestBody()
        let response: (status: Int, body: String)
        switch (method, path) {
        case (_, "/api/v1/agent-runs/models"):
            let catalog = Self.state.withLock { state -> String in
                state.catalogs += 1
                return state.fixture.catalogBody
            }
            response = (200, catalog)
        case (_, "/api/v1/agent-runs/prompts"):
            let available = Self.state.withLock { state -> Bool in
                state.prompts += 1
                return state.fixture.promptsAvailable
            }
            response = available ? (200, #"{"ok":true,"prompts":{}}"#) : (404, Self.notFound)
        case ("POST", "/api/v1/agent-runs"):
            let behavior = Self.state.withLock { state -> SmartRenameExecutionFixture.StartBehavior in
                state.starts += 1
                state.startBodies.append(body)
                return state.fixture.startBehavior
            }
            switch behavior {
            case .failStart:
                response = (
                    503,
                    #"{"ok":false,"error":{"code":"synthetic_start","message":"Synthetic start failure"}}"#
                )
            case .complete, .failRun:
                response = (200, Self.runEnvelope(status: "running", response: nil, error: nil))
            }
        case ("GET", "/api/v1/agent-runs/agr_execution0001"):
            let behavior = Self.state.withLock { state -> SmartRenameExecutionFixture.StartBehavior in
                state.fetches += 1
                return state.fixture.startBehavior
            }
            switch behavior {
            case let .complete(titleJSON):
                response = (200, Self.runEnvelope(status: "completed", response: titleJSON, error: nil))
            case .failRun:
                response = (
                    200,
                    Self.runEnvelope(
                        status: "failed",
                        response: #"{"title":"Partial synthetic title"#,
                        error: "Synthetic provider failure"
                    )
                )
            case .failStart:
                response = (200, Self.runEnvelope(status: "running", response: nil, error: nil))
            }
        case ("GET", "/api/v1/panes/p1/pi/snapshot"):
            response = Self.state.withLock { state in
                state.fixture.snapshotBody.map { (200, $0) } ?? (404, Self.notFound)
            }
        case ("GET", "/api/v1/panes/p1/output"):
            response = Self.state.withLock { state in
                guard let text = state.fixture.outputText else { return (404, Self.notFound) }
                return (
                    200,
                    "{\"ok\":true,\"pane_id\":\"p1\",\"text\":\(Self.jsonString(text)),\"revision\":1,\"truncated\":true}"
                )
            }
        case ("PATCH", "/api/v1/panes/p1"):
            let label = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            Self.state.withLock { state in
                state.renames += 1
                state.renamedLabel = label?["label"] as? String
            }
            response = (200, #"{"ok":true}"#)
        case ("GET", "/api/v1/workspaces"):
            let (label, sessionID) = Self.state.withLock { state in
                (state.renamedLabel ?? "Original title", state.fixture.paneSessionID)
            }
            response = (200, Self.workspacesBody(label: label, paneSessionID: sessionID))
        default:
            response = (404, Self.notFound)
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

    private static let notFound = #"{"ok":false,"error":{"code":"not_found","message":"Synthetic route not found"}}"#

    private static func runEnvelope(status: String, response: String?, error: String?) -> String {
        var run: [String: Any] = [
            "id": "agr_execution0001",
            "status": status,
            "prompt": "Synthetic naming prompt",
            "createdAt": "2026-09-01T12:00:00Z",
            "sessionFile": "synthetic-execution.jsonl",
        ]
        if let response { run["response"] = response }
        if let error { run["error"] = error }
        return jsonObjectString(["ok": true, "run": run])
    }

    private static func workspacesBody(label: String, paneSessionID: String?) -> String {
        var pane: [String: Any] = [
            "pane_id": "p1",
            "terminal_id": "term1",
            "workspace_id": "w1",
            "tab_id": "t1",
            "focused": true,
            "agent_status": "idle",
            "revision": 2,
            "label": label,
            "agent": paneSessionID == nil ? "zsh" : "pi",
            "display_agent": paneSessionID == nil ? "Terminal" : "Pi",
        ]
        if let paneSessionID {
            pane["pi_semantic"] = [
                "available": true, "connected": true, "protocol_version": 1,
                "session_id": paneSessionID,
            ]
        }
        let tab: [String: Any] = [
            "tab_id": "t1", "workspace_id": "w1", "number": 1, "label": "Synthetic tab",
            "focused": true, "pane_count": 1, "agent_status": "idle",
        ]
        let workspace: [String: Any] = [
            "workspace_id": "w1", "number": 1, "label": "Synthetic workspace",
            "focused": true, "pane_count": 1, "tab_count": 1, "active_tab_id": "t1",
            "agent_status": "idle", "tabs": [tab], "panes": [pane],
        ]
        return jsonObjectString(["ok": true, "workspaces": [workspace], "alerts": []])
    }

    private static func jsonObjectString(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
