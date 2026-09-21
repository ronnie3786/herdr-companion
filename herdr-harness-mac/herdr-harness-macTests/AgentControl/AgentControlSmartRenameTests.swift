import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

// These cases configure one process-wide URLProtocol fixture. Serialize them so
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

    @Test("A missing naming selection is reported without renaming or rewriting the preference")
    func missingSelectionIsReportedWithoutRenaming() async throws {
        let fixture = try makeFixture(refreshFails: false)
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            AgentControlSmartRenameURLProtocol.reset()
        }
        fixture.defaults.set("beta/beta-only", forKey: AgentModelSettings.quickChatModelKey)
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)

        await fixture.model.smartRename(fixture.pane, runner: runner)

        let counts = AgentControlSmartRenameURLProtocol.counts()
        #expect(counts.renames == 0)
        #expect(counts.refreshes == 0)
        #expect(runner.calls.isEmpty)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        let toast = try #require(fixture.model.toastMessage)
        #expect(toast.hasPrefix("Smart Rename failed"))
        #expect(toast.contains("beta/beta-only"))
        #expect(toast.contains("Desktop"))
        #expect(toast.contains("Settings"))
        #expect(fixture.defaults.string(forKey: AgentModelSettings.quickChatModelKey) == "beta/beta-only")
    }

    @Test("A naming-run failure is an actionable typed receipt that never mutates the pane")
    func failedRunReceiptPreservesTitle() async throws {
        let fixture = try makeFixture(refreshFails: false)
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            AgentControlSmartRenameURLProtocol.reset()
        }
        let runner = FakeNoteAIRunner()
        runner.mode = .throwing(AgentControlSmartRenameFixtureError(message: "Synthetic provider failure"))

        do {
            _ = try await fixture.model.smartRenameForAgentControl(fixture.pane, runner: runner) {}
            Issue.record("Expected the naming-run failure to throw")
        } catch let error as SmartRenameExecutionError {
            #expect(error.machineName == "Desktop")
            #expect(error.model == "synthetic/naming")
            #expect(error.thinkingLevel == .low)
            #expect(error.reason == "Synthetic provider failure")
        }

        let counts = AgentControlSmartRenameURLProtocol.counts()
        #expect(counts.renames == 0)
        #expect(counts.refreshes == 0)
        #expect(runner.calls.count == 1)
        #expect(fixture.model.pane(id: fixture.pane.id)?.displayTitle == "Original title")
        #expect(!fixture.model.smartRenamingPaneIDs.contains(fixture.pane.id))
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

private struct AgentControlSmartRenameFixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class AgentControlSmartRenameURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var refreshFails = false
        var renameCount = 0
        var refreshCount = 0
        var renamedTitle: String?
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
            response = (200, #"{"available":true,"session":{"id":"synthetic-session"},"entries":[{"type":"message","id":"a","message":{"role":"user","content":[{"type":"text","text":"Rename this synthetic conversation"}]}}]}"#)
        } else if path == "/api/v1/agent-runs/models" {
            response = (200, #"{"ok":true,"models":[{"provider":"synthetic","id":"naming","name":"Synthetic Naming","reasoning":true}],"default":{"provider":"synthetic","id":"naming","name":"Synthetic Naming"}}"#)
        } else if method == "PATCH", path.hasSuffix("/api/v1/panes/p1") {
            let input = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any]
            Self.state.withLock {
                $0.renameCount += 1
                $0.renamedTitle = input?["label"] as? String
            }
            response = (200, #"{"ok":true}"#)
        } else if path.hasSuffix("/api/v1/workspaces") {
            let shouldFail = Self.state.withLock { state -> Bool in
                state.refreshCount += 1
                return state.refreshFails
            }
            if shouldFail {
                response = (503, #"{"ok":false,"error":{"code":"synthetic_refresh","message":"Synthetic refresh failed"}}"#)
            } else {
                let title = Self.state.withLock { $0.renamedTitle ?? "Synthetic refreshed title" }
                let payload: [String: Any] = [
                    "ok": true,
                    "workspaces": [[
                        "workspace_id": "w1", "number": 1, "label": "Synthetic workspace",
                        "focused": true, "pane_count": 1, "tab_count": 1,
                        "active_tab_id": "t1", "agent_status": "idle",
                        "panes": [[
                            "pane_id": "p1", "terminal_id": "term1", "workspace_id": "w1",
                            "tab_id": "t1", "focused": true, "agent_status": "idle",
                            "revision": 2, "cwd": "/tmp/synthetic", "label": title,
                            "agent": "pi", "display_agent": "Pi",
                            "pi_semantic": [
                                "available": true, "connected": true, "protocol_version": 1,
                                "session_id": "synthetic-session",
                            ],
                        ]],
                    ]],
                    "alerts": [],
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                response = (200, String(decoding: data, as: UTF8.self))
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
