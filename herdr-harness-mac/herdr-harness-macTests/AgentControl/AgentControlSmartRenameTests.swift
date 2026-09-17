import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

// Both cases configure one process-wide URLProtocol fixture. Serialize them so
// suspension during a request cannot replace another case's response state.
@Suite("Agent control Smart Rename refresh", .serialized)
@MainActor
struct AgentControlSmartRenameTests {
    @Test("Manual Smart Rename refreshes the pane title before reporting success")
    func refreshesRenamedPane() async throws {
        let fixture = try makeFixture(refreshFails: false)
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            AgentControlSmartRenameURLProtocol.reset()
        }
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic refreshed title"}"#)

        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = AgentControlSmartRenameURLProtocol.counts()
        #expect(counts.renames == 1)
        #expect(counts.refreshes == 1)
        #expect(runner.calls.count == 1)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Synthetic refreshed title")
        #expect(fixture.model.toastMessage == "Pane renamed")
    }

    @Test("A post-rename refresh failure reports the completed mutation without guessing success")
    func labelsPostEffectRefreshFailure() async throws {
        let fixture = try makeFixture(refreshFails: true)
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            AgentControlSmartRenameURLProtocol.reset()
        }
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic renamed title"}"#)

        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = AgentControlSmartRenameURLProtocol.counts()
        #expect(counts.renames == 1)
        #expect(counts.refreshes == 1)
        #expect(runner.calls.count == 1)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        #expect(fixture.model.toastMessage?.contains("Pane renamed to “Synthetic renamed title”") == true)
        #expect(fixture.model.toastMessage?.contains("couldn't refresh") == true)
        #expect(fixture.model.toastMessage?.hasPrefix("Smart Rename failed") == false)
    }

    private func makeFixture(refreshFails: Bool) throws -> (
        model: HerdrAppModel,
        pane: HerdrPane,
        defaults: UserDefaults,
        suite: String
    ) {
        AgentControlSmartRenameURLProtocol.configure(refreshFails: refreshFails)
        let suite = "AgentControlSmartRenameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let credentials = TestCredentialStore()
        let machine = HerdrMachine(id: "desktop", name: "Desktop", urlString: "http://localhost:9092")
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "synthetic-token"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AgentControlSmartRenameURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let semantic = try JSONDecoder().decode(
            PiSemanticCapability.self,
            from: Data(#"{"available":true,"connected":true,"protocol_version":1,"session_id":"synthetic-session"}"#.utf8)
        )
        let pane = HerdrPane(
            paneID: "p1",
            terminalID: "term1",
            workspaceID: "w1",
            tabID: "t1",
            focused: true,
            agentStatus: .idle,
            revision: 1,
            cwd: "/tmp/synthetic",
            foregroundCWD: nil,
            label: "Original title",
            title: nil,
            agent: "pi",
            displayAgent: "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil,
            piSemantic: semantic
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
            panes: [pane]
        ).stamped(machineID: machine.id)]
        return (model, pane, defaults, suite)
    }
}

private final class AgentControlSmartRenameURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var refreshFails = false
        var renameCount = 0
        var refreshCount = 0
    }

    private static let state = Mutex(State())

    static func configure(refreshFails: Bool) {
        state.withLock {
            $0 = State(refreshFails: refreshFails)
        }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func counts() -> (renames: Int, refreshes: Int) {
        state.withLock { ($0.renameCount, $0.refreshCount) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let response: (status: Int, body: String)
        if path.hasSuffix("/api/v1/panes/p1/pi/snapshot") {
            response = (200, #"{"available":true,"entries":[{"type":"message","id":"a","message":{"role":"user","content":[{"type":"text","text":"Rename this synthetic conversation"}]}}]}"#)
        } else if method == "PATCH", path.hasSuffix("/api/v1/panes/p1") {
            Self.state.withLock { $0.renameCount += 1 }
            response = (200, #"{"ok":true}"#)
        } else if path.hasSuffix("/api/v1/workspaces") {
            let shouldFail = Self.state.withLock { state -> Bool in
                state.refreshCount += 1
                return state.refreshFails
            }
            if shouldFail {
                response = (503, #"{"ok":false,"error":{"code":"synthetic_refresh","message":"Synthetic refresh failed"}}"#)
            } else {
                response = (200, #"{"ok":true,"workspaces":[{"workspace_id":"w1","number":1,"label":"Synthetic workspace","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"t1","agent_status":"idle","panes":[{"pane_id":"p1","terminal_id":"term1","workspace_id":"w1","tab_id":"t1","focused":true,"agent_status":"idle","revision":2,"cwd":"/tmp/synthetic","label":"Synthetic refreshed title","agent":"pi","display_agent":"Pi","pi_semantic":{"available":true,"connected":true,"protocol_version":1,"session_id":"synthetic-session"}}]}],"alerts":[]}"#)
            }
        } else {
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
}
