import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Smart pane rename", .serialized)
@MainActor
struct SmartPaneRenameTests {
    @Test("An acknowledged prompt renames a pane while its snapshot is still empty")
    func acknowledgedPromptWithEmptySnapshot() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneLabel = "Original title"
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        try await fixture.model.sendPiConversationPrompt(
            "Investigate the synthetic irrigation leak",
            disposition: .prompt,
            to: fixture.pane
        )
        #expect(SmartRenameFixtureURLProtocol.counts().submissions == 1)

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic irrigation leak"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = SmartRenameFixtureURLProtocol.counts()
        #expect(counts.snapshots == 1)
        #expect(counts.renames == 1)
        #expect(counts.refreshes == 1)
        #expect(runner.calls.count == 1)
        let call = try #require(runner.calls.first)
        #expect(call.machineID == "desktop")
        #expect(call.mode == .ask)
        #expect(call.model == "synthetic/naming")
        #expect(call.thinkingLevel == "low")
        #expect(call.prompt.contains("Investigate the synthetic irrigation leak"))
        #expect(fixture.model.toastMessage == "Pane renamed")
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Synthetic renamed title")
    }

    @Test("An acknowledged pane-id prompt also bridges snapshot lag")
    func acknowledgedPaneIDPromptBridgesLag() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        try await fixture.model.sendPiPrompt(paneID: fixture.pane.id, text: "Synthetic pane-id instruction")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic pane instruction"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("Synthetic pane-id instruction"))
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
    }

    @Test("A controllable shell pane is named from bounded terminal output")
    func shellPaneUsesTerminalOutput() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = nil
        configuration.paneLabel = nil
        configuration.outputText = "\u{1B}[32m$ npm test\u{1B}[0m\n> synthetic suite\n12 passing"
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic suite passing"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = SmartRenameFixtureURLProtocol.counts()
        #expect(counts.snapshots == 0)
        #expect(counts.outputs == 1)
        #expect(counts.renames == 1)
        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("npm test"))
        #expect(call.prompt.contains("12 passing"))
        #expect(!call.prompt.contains("\u{1B}"))
        #expect(fixture.model.toastMessage == "Pane renamed")
    }

    @Test("A pane without transcript or output is named from labels and folder metadata")
    func metadataOnlyPane() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = nil
        configuration.paneLabel = nil
        configuration.paneCWD = "/tmp/synthetic-garden"
        configuration.workspaceLabel = "Synthetic Garden"
        configuration.tabLabel = "Terminal"
        configuration.outputText = nil
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic garden terminal"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().outputs == 1)
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("Synthetic Garden"))
        #expect(call.prompt.contains("Terminal"))
        #expect(call.prompt.contains("/tmp/synthetic-garden"))
    }

    @Test("A genuinely context-free pane reports missing context without requiring a conversation")
    func contextFreePaneNeverRequiresAConversation() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = nil
        configuration.paneLabel = nil
        configuration.paneTitle = nil
        configuration.paneTerminalTitle = nil
        configuration.paneCWD = nil
        configuration.workspaceLabel = ""
        configuration.tabLabel = ""
        configuration.outputText = nil
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(runner.calls.isEmpty)
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.toastMessage?.contains("no readable context") == true)
        #expect(fixture.model.toastMessage?.lowercased().contains("conversation") != true)
        #expect(fixture.model.toastMessage?.lowercased().contains("reply") != true)
    }

    @Test("Failed submissions are never used as naming context")
    func failedSubmissionsAreNotCached() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = "synthetic-session"
        configuration.paneLabel = nil
        configuration.paneCWD = nil
        configuration.workspaceLabel = ""
        configuration.tabLabel = ""
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        configuration.submissionFails = true
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let sent = await fixture.model.sendPrompt("Unsent synthetic instruction", to: fixture.pane)
        #expect(sent == false)
        var piThrew = false
        do {
            try await fixture.model.sendPiConversationPrompt(
                "Also unsent synthetic instruction",
                disposition: .prompt,
                to: fixture.pane
            )
        } catch {
            piThrew = true
        }
        #expect(piThrew)
        #expect(SmartRenameFixtureURLProtocol.counts().submissions == 2)

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(runner.calls.isEmpty)
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
    }

    @Test("A prompt accepted for another session is never merged into the current conversation")
    func crossSessionCacheExclusion() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = "session-a"
        configuration.paneLabel = "Session A pane"
        configuration.snapshotBody = #"{"available":true,"session":{"id":"session-a"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        try await fixture.model.sendPiConversationPrompt(
            "First session secret prompt",
            disposition: .prompt,
            to: fixture.pane
        )

        // The pane is now hosting a different session with the same scoped id.
        var replacementConfiguration = configuration
        replacementConfiguration.paneSessionID = "session-b"
        let replacement = makeSmartRenamePane(replacementConfiguration, machineID: "desktop")
        fixture.model.workspaces[0].panes = [replacement]

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Session B pane"}"#)
        await fixture.model.smartRename(replacement, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("Session A pane"))
        #expect(!call.prompt.contains("First session secret prompt"))
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
    }

    @Test("An explicitly mismatched snapshot session is rejected rather than used")
    func mismatchedSnapshotSessionIsRejected() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = "session-a"
        configuration.paneLabel = "Session A pane"
        configuration.snapshotBody = #"""
        {"available":true,"session":{"id":"session-b"},"entries":[
          {"type":"message","id":"x","message":{"role":"user","content":[{"type":"text","text":"Another conversation private detail"}]}}
        ]}
        """#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        try await fixture.model.sendPiConversationPrompt(
            "Current conversation prompt",
            disposition: .prompt,
            to: fixture.pane
        )

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Current conversation"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("Current conversation prompt"))
        #expect(!call.prompt.contains("Another conversation private detail"))
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
    }

    @Test("Naming resolves models and executes on the pane's own machine")
    func twoMachineRouting() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneLabel = "Beta pane"
        configuration.catalogByPort = [
            9411: #"{"ok":true,"models":[{"provider":"alpha","id":"alpha-only","name":"Alpha Only","reasoning":true}],"default":{"provider":"alpha","id":"alpha-only","name":"Alpha Only"}}"#,
            9412: #"{"ok":true,"models":[{"provider":"beta","id":"beta-only","name":"Beta Only","reasoning":true}],"default":{"provider":"beta","id":"beta-only","name":"Beta Only"}}"#,
        ]
        let fixture = try makeTwoMachineFixture(configuration)
        defer { tearDown(fixture.model, defaults: fixture.defaults, suite: fixture.suite) }
        fixture.defaults.set("alpha/alpha-only", forKey: AgentModelSettings.quickChatModelKey)

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Beta naming"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.machineID == "beta")
        #expect(call.model == "beta/beta-only")
        #expect(call.thinkingLevel == "low")
        let fetches = SmartRenameFixtureURLProtocol.catalogFetchPorts()
        #expect(fetches[9412] == 1)
        #expect(fetches[9411] == nil)
        // The unavailable preference falls back with an actionable notice
        // instead of being rewritten.
        #expect(fixture.model.toastMessage?.contains("alpha/alpha-only") == true)
        #expect(fixture.model.toastMessage?.contains("Beta") == true)
        #expect(fixture.defaults.string(forKey: AgentModelSettings.quickChatModelKey) == "alpha/alpha-only")
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
    }

    @Test("A second Smart Rename for the same pane is ignored while one is running")
    func duplicateRequestsAreIgnored() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"First title"}"#)
        runner.onRun = { await fixture.model.smartRename(fixture.pane, runner: runner) }
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(runner.calls.count == 1)
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
    }

    @Test("Cancellation preserves the original title and never mutates")
    func cancellationPreservesTheTitle() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .throwing(CancellationError())
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
    }

    @Test("A manual title edit during the naming run wins over the AI title")
    func manualEditWins() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"AI title"}"#)
        runner.onRun = {
            var manual = configuration
            manual.paneLabel = "Manual title"
            fixture.model.workspaces[0].panes = [makeSmartRenamePane(manual, machineID: "desktop")]
        }
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Manual title")
        #expect(fixture.model.toastMessage?.contains("changed") == true)
    }

    @Test("A replaced terminal prevents a stale rename")
    func replacedTerminalIsRejected() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = nil
        configuration.paneLabel = "Shell pane"
        configuration.outputText = "$ echo synthetic"
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Stale title"}"#)
        runner.onRun = {
            var replaced = configuration
            replaced.paneTerminalID = "term2"
            fixture.model.workspaces[0].panes = [makeSmartRenamePane(replaced, machineID: "desktop")]
        }
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.toastMessage?.contains("changed") == true)
    }

    @Test("A connection change prevents a stale rename")
    func connectionChangeIsRejected() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Stale title"}"#)
        runner.onRun = { fixture.model.connectionGeneration += 1 }
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.toastMessage?.contains("changed") == true)
    }

    @Test("Ordinary output revisions do not invalidate an in-flight rename")
    func ordinaryOutputRevisionsDoNotInvalidate() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.paneSessionID = nil
        configuration.paneLabel = "Shell pane"
        configuration.outputText = "$ echo synthetic"
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Fresh title"}"#)
        runner.onRun = {
            var updated = configuration
            updated.paneRevision = 7
            updated.paneTerminalTitle = "zsh: synthetic new output"
            updated.outputText = "$ echo synthetic\nnew output arrived"
            fixture.model.workspaces[0].panes = [makeSmartRenamePane(updated, machineID: "desktop")]
        }
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(SmartRenameFixtureURLProtocol.counts().renames == 1)
        #expect(fixture.model.toastMessage == "Pane renamed")
    }

    @Test("A post-rename refresh failure reports the completed mutation")
    func postRenameRefreshFailure() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        configuration.refreshFails = true
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic renamed title"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = SmartRenameFixtureURLProtocol.counts()
        #expect(counts.renames == 1)
        #expect(counts.refreshes == 1)
        #expect(fixture.model.toastMessage?.contains("Pane renamed to “Synthetic renamed title”") == true)
        #expect(fixture.model.toastMessage?.contains("couldn't refresh") == true)
        #expect(fixture.model.toastMessage?.hasPrefix("Smart Rename failed") == false)
    }

    @Test("A catalog failure keeps the title and reports an actionable reason")
    func catalogFailurePreservesTheTitle() async throws {
        var configuration = SmartRenameFixtureConfiguration()
        configuration.snapshotBody = #"{"available":true,"session":{"id":"synthetic-session"},"entries":[]}"#
        configuration.defaultCatalog = #"{"ok":false,"error":{"code":"synthetic_catalog","message":"Synthetic catalog failure"}}"#
        let fixture = try makeFixture(configuration)
        defer { tearDown(fixture) }

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await fixture.model.smartRename(fixture.pane, runner: runner)

        #expect(runner.calls.isEmpty)
        #expect(SmartRenameFixtureURLProtocol.counts().renames == 0)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        #expect(fixture.model.toastMessage?.contains("Couldn't read the models available on Desktop") == true)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: HerdrAppModel
        let pane: HerdrPane
        let defaults: UserDefaults
        let suite: String
    }

    private func makeFixture(_ configuration: SmartRenameFixtureConfiguration) throws -> Fixture {
        let machine = HerdrMachine(id: "desktop", name: "Desktop", urlString: "http://localhost:9092")
        let made = try makeModel(machines: [machine], configuration: configuration, paneMachineID: machine.id)
        return Fixture(model: made.model, pane: made.pane, defaults: made.defaults, suite: made.suite)
    }

    private func makeTwoMachineFixture(
        _ configuration: SmartRenameFixtureConfiguration
    ) throws -> (model: HerdrAppModel, pane: HerdrPane, defaults: UserDefaults, suite: String) {
        let alpha = HerdrMachine(id: "alpha", name: "Alpha", urlString: "http://127.0.0.1:9411")
        let beta = HerdrMachine(id: "beta", name: "Beta", urlString: "http://127.0.0.1:9412")
        return try makeModel(machines: [alpha, beta], configuration: configuration, paneMachineID: beta.id)
    }

    private func makeModel(
        machines: [HerdrMachine],
        configuration: SmartRenameFixtureConfiguration,
        paneMachineID: String
    ) throws -> (model: HerdrAppModel, pane: HerdrPane, defaults: UserDefaults, suite: String) {
        SmartRenameFixtureURLProtocol.configure(configuration)
        let suite = "SmartPaneRenameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let credentials = TestCredentialStore()
        for machine in machines {
            credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        }
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SmartRenameFixtureURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        model.machines = machines
        model.clientFactory = { configuration in
            HerdrAPIClient(configuration: configuration, session: session)
        }
        for machine in machines {
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
            model.machineStates[machine.id] = .live
        }
        let pane = makeSmartRenamePane(configuration, machineID: paneMachineID)
        model.workspaces = [
            makeSmartRenameWorkspace(configuration, machineID: paneMachineID, pane: pane)
        ]
        return (model, pane, defaults, suite)
    }

    private func tearDown(_ fixture: Fixture) {
        tearDown(fixture.model, defaults: fixture.defaults, suite: fixture.suite)
    }

    private func tearDown(_ model: HerdrAppModel, defaults: UserDefaults, suite: String) {
        model.clientFactory = { HerdrAPIClient(configuration: $0) }
        defaults.removePersistentDomain(forName: suite)
        SmartRenameFixtureURLProtocol.reset()
    }
}

private struct SmartRenameFixtureConfiguration: Sendable {
    var paneSessionID: String? = "synthetic-session"
    var paneLabel: String? = "Original title"
    var paneTitle: String? = nil
    var paneTerminalTitle: String? = nil
    var paneTerminalID: String = "term1"
    var paneRevision: Int = 1
    var paneCWD: String? = nil
    var tabLabel: String = "Synthetic tab"
    var workspaceLabel: String = "Synthetic workspace"
    var refreshedLabel: String = "Synthetic renamed title"
    var snapshotBody: String? = nil
    var outputText: String? = nil
    var submissionFails = false
    var refreshFails = false
    var catalogByPort: [Int: String] = [:]
    var defaultCatalog: String = Self.fallbackCatalog

    static let fallbackCatalog = #"{"ok":true,"models":[{"provider":"synthetic","id":"naming","name":"Synthetic Naming","reasoning":true,"context_window":64000}],"default":{"provider":"synthetic","id":"naming","name":"Synthetic Naming"}}"#
}

private func makeSmartRenamePane(
    _ configuration: SmartRenameFixtureConfiguration,
    machineID: String
) -> HerdrPane {
    HerdrPane(
        paneID: "p1",
        terminalID: configuration.paneTerminalID,
        workspaceID: "w1",
        tabID: "t1",
        focused: true,
        agentStatus: .idle,
        revision: configuration.paneRevision,
        cwd: configuration.paneCWD,
        foregroundCWD: nil,
        label: configuration.paneLabel,
        title: configuration.paneTitle,
        agent: configuration.paneSessionID == nil ? "zsh" : "pi",
        displayAgent: configuration.paneSessionID == nil ? "Terminal" : "Pi",
        terminalTitle: nil,
        terminalTitleStripped: configuration.paneTerminalTitle,
        piSemantic: makeSmartRenameSemantic(configuration)
    ).stamped(machineID: machineID)
}

private func makeSmartRenameSemantic(
    _ configuration: SmartRenameFixtureConfiguration
) -> PiSemanticCapability? {
    guard let session = configuration.paneSessionID else { return nil }
    return try? JSONDecoder().decode(
        PiSemanticCapability.self,
        from: Data("{\"available\":true,\"connected\":true,\"protocol_version\":1,\"session_id\":\"\(session)\"}".utf8)
    )
}

private func makeSmartRenameWorkspace(
    _ configuration: SmartRenameFixtureConfiguration,
    machineID: String,
    pane: HerdrPane
) -> HerdrWorkspace {
    let tab = HerdrTab(
        tabID: "t1",
        workspaceID: "w1",
        number: 1,
        label: configuration.tabLabel,
        focused: true,
        paneCount: 1,
        agentStatus: .idle
    ).stamped(machineID: machineID)
    return HerdrWorkspace(
        workspaceID: "w1",
        number: 1,
        label: configuration.workspaceLabel,
        focused: true,
        paneCount: 1,
        tabCount: 1,
        activeTabID: "t1",
        agentStatus: .idle,
        tabs: [tab],
        panes: [pane]
    ).stamped(machineID: machineID)
}

/// Answers catalogs, submissions, snapshots, output, and rename routes from
/// synthetic bodies. Tests configure one process-wide fixture and this suite is
/// serialized so a suspension in one case cannot alter another case's state.
private final class SmartRenameFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var configuration = SmartRenameFixtureConfiguration()
        var submissions = 0
        var snapshots = 0
        var outputs = 0
        var renames = 0
        var refreshes = 0
        var catalogFetches: [Int: Int] = [:]
    }

    private static let state = Mutex(State())

    static func configure(_ configuration: SmartRenameFixtureConfiguration) {
        state.withLock { $0 = State(configuration: configuration) }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func counts() -> (
        submissions: Int,
        snapshots: Int,
        outputs: Int,
        renames: Int,
        refreshes: Int
    ) {
        state.withLock { ($0.submissions, $0.snapshots, $0.outputs, $0.renames, $0.refreshes) }
    }

    static func catalogFetchPorts() -> [Int: Int] {
        state.withLock { $0.catalogFetches }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let configuration = Self.state.withLock { $0.configuration }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let response: (status: Int, body: String)
        switch (method, path) {
        case (_, "/api/v1/agent-runs/models"):
            Self.state.withLock { $0.catalogFetches[url.port ?? 0, default: 0] += 1 }
            response = (200, configuration.catalogByPort[url.port ?? 0] ?? configuration.defaultCatalog)
        case ("GET", "/api/v1/workspaces"):
            Self.state.withLock { $0.refreshes += 1 }
            response = configuration.refreshFails
                ? (503, #"{"ok":false,"error":{"code":"synthetic_refresh","message":"Synthetic refresh failed"}}"#)
                : (200, Self.workspacesBody(configuration))
        case ("GET", let path) where path.hasSuffix("/pi/snapshot"):
            Self.state.withLock { $0.snapshots += 1 }
            response = configuration.snapshotBody.map { (200, $0) } ?? (404, Self.notFound)
        case ("GET", let path) where path.hasSuffix("/output"):
            Self.state.withLock { $0.outputs += 1 }
            if let text = configuration.outputText {
                response = (
                    200,
                    "{\"ok\":true,\"pane_id\":\"p1\",\"text\":\(Self.jsonString(text)),\"revision\":1,\"truncated\":true}"
                )
            } else {
                response = (404, Self.notFound)
            }
        case ("POST", let path) where path.hasSuffix("/pi/prompt")
            || path.hasSuffix("/prompt") || path.hasSuffix("/run"):
            Self.state.withLock { $0.submissions += 1 }
            response = configuration.submissionFails
                ? (500, #"{"ok":false,"error":{"code":"synthetic_submission","message":"Synthetic submission failed"}}"#)
                : (200, #"{"ok":true,"accepted":true}"#)
        case ("PATCH", let path) where path.hasSuffix("/panes/p1"):
            Self.state.withLock { $0.renames += 1 }
            response = (200, #"{"ok":true}"#)
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

    private static func workspacesBody(_ configuration: SmartRenameFixtureConfiguration) -> String {
        var pane = "{\"pane_id\":\"p1\",\"terminal_id\":\(jsonString(configuration.paneTerminalID)),\"workspace_id\":\"w1\",\"tab_id\":\"t1\",\"focused\":true,\"agent_status\":\"idle\",\"revision\":2,\"cwd\":\(jsonString(configuration.paneCWD)),\"label\":\(jsonString(configuration.refreshedLabel)),\"agent\":\"\(configuration.paneSessionID == nil ? "zsh" : "pi")\",\"display_agent\":\"\(configuration.paneSessionID == nil ? "Terminal" : "Pi")\""
        if let session = configuration.paneSessionID {
            pane += ",\"pi_semantic\":{\"available\":true,\"connected\":true,\"protocol_version\":1,\"session_id\":\"\(session)\"}"
        }
        pane += "}"
        let tab = "{\"tab_id\":\"t1\",\"workspace_id\":\"w1\",\"number\":1,\"label\":\(jsonString(configuration.tabLabel)),\"focused\":true,\"pane_count\":1,\"agent_status\":\"idle\"}"
        return "{\"ok\":true,\"workspaces\":[{\"workspace_id\":\"w1\",\"number\":1,\"label\":\(jsonString(configuration.workspaceLabel)),\"focused\":true,\"pane_count\":1,\"tab_count\":1,\"active_tab_id\":\"t1\",\"agent_status\":\"idle\",\"tabs\":[\(tab)],\"panes\":[\(pane)]}],\"alerts\":[]}"
    }

    private static func jsonString(_ value: String?) -> String {
        guard let value else { return "null" }
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
