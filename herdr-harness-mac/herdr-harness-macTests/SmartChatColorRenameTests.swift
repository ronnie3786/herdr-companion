import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Smart chat color rename") @MainActor
struct SmartChatColorRenameTests {
    @Test("Uses bounded conversation context and Quick Chat, renaming only the shared label")
    func successfulRename() async throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = model.workspaces
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"GARDEN-42 Repair irrigation"}"#)
        await model.smartRenameChatColor(.sage, runner: runner)
        #expect(model.chatTabColors.label(for: .sage) == "GARDEN-42 Repair irrigation")
        #expect(model.workspaces == before)
        #expect(runner.calls.count == 1)
        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("GARDEN-42"))
        #expect(call.prompt.contains("Repair irrigation"))
        #expect(call.thinkingLevel == "low")
        #expect(model.chatTabColors.smartRenaming.isEmpty)
        #expect(ChatTabColorStore(defaults: defaults).label(for: .sage) == "GARDEN-42 Repair irrigation")
    }

    @Test("A manual label edit wins over an in-flight AI result")
    func manualEditWins() async throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"AI suggestion"}"#)
        runner.onRun = { model.chatTabColors.rename(.sage, to: "My label") }
        await model.smartRenameChatColor(.sage, runner: runner)
        #expect(model.chatTabColors.label(for: .sage) == "My label")
        #expect(model.chatTabColors.smartRenaming.isEmpty)
    }

    @Test("Reassignment and new sessions discard stale names")
    func staleResults() async throws {
        for changeSession in [false, true] {
            let (model, defaults, suite) = try fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let runner = FakeNoteAIRunner()
            runner.mode = .succeed(#"{"title":"Stale suggestion"}"#)
            runner.onRun = {
                if changeSession {
                    model.workspaces[0].panes.removeAll()
                } else {
                    model.chatTabColors.assign(.rose, to: "desktop|t1")
                }
            }
            await model.smartRenameChatColor(.sage, runner: runner)
            #expect(model.chatTabColors.label(for: .sage) == "Sage")
            #expect(model.chatTabColors.smartRenaming.isEmpty)
        }
    }

    @Test("Invalid output and failure preserve the label; duplicate requests are ignored")
    func failuresAndDuplicates() async throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = FakeNoteAIRunner()
        runner.mode = .succeed("not JSON")
        runner.onRun = { await model.smartRenameChatColor(.sage, runner: runner) }
        await model.smartRenameChatColor(.sage, runner: runner)
        #expect(runner.calls.count == 1)
        #expect(model.chatTabColors.label(for: .sage) == "Sage")
        runner.onRun = nil
        runner.mode = .throwing(URLError(.notConnectedToInternet))
        await model.smartRenameChatColor(.sage, runner: runner)
        #expect(model.chatTabColors.label(for: .sage) == "Sage")
        #expect(model.chatTabColors.smartRenaming.isEmpty)
    }

    private func fixture() throws -> (HerdrAppModel, UserDefaults, String) {
        let suite = "SmartChatColorRenameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults, configuredMachines: [])
        let machine = HerdrMachine(id: "desktop", name: "Desktop", urlString: "http://localhost:9092")
        let config = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ChatColorSnapshotURLProtocol.self]
        let client = HerdrAPIClient(configuration: config, session: URLSession(configuration: sessionConfig))
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let semantic = try JSONDecoder().decode(PiSemanticCapability.self, from: Data(#"{"available":true,"connected":true,"sessionId":"sample-session"}"#.utf8))
        let pane = HerdrPane(
            paneID: "p1", terminalID: "p1", workspaceID: "w1", tabID: "t1", focused: true,
            agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil, label: "Repair irrigation",
            title: nil, agent: "pi", displayAgent: "Pi", terminalTitle: nil, terminalTitleStripped: nil,
            piSemantic: semantic
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1", number: 1, label: "Garden", focused: true, paneCount: 1,
            tabCount: 1, activeTabID: "t1", agentStatus: .idle, panes: [pane]
        ).stamped(machineID: "desktop")]
        model.chatTabColors.assign(.sage, to: "desktop|t1")
        return (model, defaults, suite)
    }
}

private final class ChatColorSnapshotURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let isSnapshot = url.path.hasSuffix("/pi/snapshot")
        let response = HTTPURLResponse(url: url, statusCode: isSnapshot ? 200 : 404, httpVersion: nil, headerFields: nil)!
        let body = isSnapshot ? #"{"available":true,"entries":[{"type":"message","id":"a","message":{"role":"user","content":[{"type":"text","text":"Work on GARDEN-42 Repair irrigation"}]}}]}"# : #"{"error":"Not available"}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
