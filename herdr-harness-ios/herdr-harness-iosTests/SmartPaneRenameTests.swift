import Foundation
import Testing
@testable import herdr_harness_ios

@MainActor
@Suite("iOS Smart Rename", .serialized)
struct SmartPaneRenameTests {
    @Test("Names on the session's machine in a separate low-thinking run, then refreshes its title")
    func livePipeline() async throws {
        let (model, pane) = try fixture()
        model.setAgentModel("example/quick")
        await model.smartRename(pane)
        let requests = RenameSessionURLProtocol.state.requests
        #expect(requests.allSatisfy { $0.host == "secondary.example" })
        let start = try #require(requests.first { $0.method == "POST" })
        #expect(start.path == "/api/v1/agent-runs")
        #expect(start.body["mode"] == nil) // Missing mode is the server's read-only Ask mode.
        #expect(start.body["thinkingLevel"] as? String == "low")
        #expect(start.body["model"] as? String == "example/quick")
        #expect((start.body["prompt"] as? String)?.contains("Fix garden irrigation") == true)
        #expect(requests.contains { $0.method == "DELETE" && $0.path == "/api/v1/agent-runs/naming-run" })
        #expect(requests.filter { $0.method == "PATCH" }.count == 1)
        #expect(model.pane(id: pane.id)?.displayTitle == "Fix garden irrigation")
        #expect(model.smartRenamingPaneIDs.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("Manual renaming wins even when the visible label has not refreshed yet")
    func manualRenameWins() async throws {
        let (model, pane) = try fixture()
        let runner = StubTitleRunner()
        runner.onRun = {
            // Demo perform does not change the snapshot, exercising the revision guard.
            model.isDemoMode = true
            await model.rename(pane, label: "My chosen title")
        }
        await model.smartRename(pane, runner: runner)
        #expect(model.toastMessage == "Chat changed while naming it. Try Smart Rename again.")
        #expect(RenameSessionURLProtocol.state.requests.isEmpty)
        #expect(model.smartRenamingPaneIDs.isEmpty)
    }

    @Test("Removed or replaced sessions cannot be renamed by an old result", arguments: [false, true])
    func changedSession(replaced: Bool) async throws {
        let (model, pane) = try fixture()
        let replacement = try Self.workspace(sessionID: "new-session")
        let runner = StubTitleRunner()
        runner.onRun = { model.workspaces = replaced ? [replacement] : [] }
        await model.smartRename(pane, runner: runner)
        #expect(model.toastMessage == "Chat changed while naming it. Try Smart Rename again.")
        #expect(RenameSessionURLProtocol.state.requests.isEmpty)
    }

    @Test("Duplicate requests are ignored while naming is in flight")
    func duplicate() async throws {
        let (model, pane) = try fixture()
        let runner = StubTitleRunner()
        runner.onRun = {
            #expect(model.smartRenamingPaneIDs.contains(pane.id))
            await model.smartRename(pane, runner: runner)
        }
        await model.smartRename(pane, runner: runner)
        #expect(runner.count == 1)
        #expect(model.smartRenamingPaneIDs.isEmpty)
    }

    @Test("Cancellation never applies the generated title")
    func cancellation() async throws {
        let (model, pane) = try fixture()
        let runner = StubTitleRunner()
        runner.onRun = { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { await model.smartRename(pane, runner: runner) }.value
        #expect(model.toastMessage == "Smart Rename cancelled.")
        #expect(model.smartRenamingPaneIDs.isEmpty)
        #expect(RenameSessionURLProtocol.state.requests.isEmpty)
    }

    @Test("Offline sessions do not start naming")
    func offline() async throws {
        let (model, pane) = try fixture()
        model.machineStates[pane.machineID] = .disconnected
        let runner = StubTitleRunner()
        await model.smartRename(pane, runner: runner)
        #expect(runner.count == 0)
        #expect(RenameSessionURLProtocol.state.requests.isEmpty)
    }

    @Test("Invalid output never renames a pane and releases the in-flight guard")
    func invalidOutput() async throws {
        let (model, pane) = try fixture()
        let runner = StubTitleRunner()
        runner.response = "A title without JSON"
        await model.smartRename(pane, runner: runner)
        #expect(RenameSessionURLProtocol.state.requests.isEmpty)
        #expect(model.toastMessage?.contains("valid short title") == true)
        #expect(model.smartRenamingPaneIDs.isEmpty)
    }

    @Test("Empty conversations do not start an AI run")
    func emptyConversation() async throws {
        let (model, pane) = try fixture()
        RenameSessionURLProtocol.state.emptyConversation = true
        await model.smartRename(pane)
        #expect(RenameSessionURLProtocol.state.requests.map(\.method) == ["GET"])
        #expect(model.errorMessage?.contains("no readable conversation") == true)
        #expect(model.smartRenamingPaneIDs.isEmpty)
    }

    @Test("Failed runs report an error, clean up, and leave the existing title")
    func failedRun() async throws {
        let (model, pane) = try fixture()
        RenameSessionURLProtocol.state.failedRun = true
        await model.smartRename(pane)
        #expect(model.errorMessage?.contains("Example provider unavailable") == true)
        #expect(!RenameSessionURLProtocol.state.requests.contains { $0.method == "PATCH" })
        #expect(RenameSessionURLProtocol.state.requests.contains { $0.method == "DELETE" })
        #expect(model.smartRenamingPaneIDs.isEmpty)
    }

    private func fixture() throws -> (HerdrAppModel, HerdrPane) {
        RenameSessionURLProtocol.state.reset()
        let defaults = try #require(UserDefaults(suiteName: "SmartPaneRenameTests"))
        defaults.removePersistentDomain(forName: "SmartPaneRenameTests")
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults, bootstrapMachines: [])
        let primary = HerdrMachine(id: "primary", name: "Primary", urlString: "https://primary.example")
        let machine = HerdrMachine(id: "secondary", name: "Secondary", urlString: "https://secondary.example")
        model.machines = [primary, machine]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenameSessionURLProtocol.self]
        let session = URLSession(configuration: config)
        model.clientFactory = { HerdrAPIClient(configuration: $0, session: session) }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        model.workspaces = [try Self.workspace()]
        return (model, try #require(model.pane(id: "secondary|w1:p1")))
    }

    fileprivate static func workspace(sessionID: String = "original-session", title: String = "Original title") throws -> HerdrWorkspace {
        let json: [String: Any] = ["workspace_id": "w1", "label": "Garden", "panes": [
            ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "pi", "title": title,
             "pi_semantic": ["available": true, "protocolVersion": 1, "sessionId": sessionID]]
        ]]
        return try JSONDecoder().decode(HerdrWorkspace.self, from: JSONSerialization.data(withJSONObject: json)).stamped(machineID: "secondary")
    }
}

@MainActor
private final class StubTitleRunner: SmartPaneTitleRunning {
    var count = 0
    var response = #"{"title":"Fix garden irrigation"}"#
    var onRun: (() async -> Void)?
    func response(for pane: HerdrPane, model: HerdrAppModel) async throws -> String {
        count += 1
        await onRun?()
        return response
    }
}

private final class RenameSessionURLProtocol: URLProtocol {
    static let state = RenameSessionRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.reply(to: request)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RenameSessionRequests: @unchecked Sendable {
    struct Request { let method: String; let host: String; let path: String; let body: [String: Any] }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var empty = false
    private var failed = false
    private var title = "Original title"
    var requests: [Request] { lock.withLock { recorded } }
    var emptyConversation: Bool {
        get { lock.withLock { empty } }
        set { lock.withLock { empty = newValue } }
    }
    var failedRun: Bool {
        get { lock.withLock { failed } }
        set { lock.withLock { failed = newValue } }
    }
    func reset() { lock.withLock { recorded = []; empty = false; failed = false; title = "Original title" } }
    func reply(to request: URLRequest) -> Data {
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                bodyData.append(bytes, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        return lock.withLock {
            let path = request.url?.path ?? ""
            recorded.append(Request(method: request.httpMethod ?? "GET", host: request.url?.host ?? "", path: path, body: body))
            var json: [String: Any] = ["ok": true]
            if path.hasSuffix("/pi/snapshot") {
                json["entries"] = empty ? [] : [["type": "message", "id": "a", "message": ["role": "user", "content": [["type": "text", "text": "Fix garden irrigation"]]]]]
            } else if path.contains("/agent-runs") {
                json["run"] = ["id": "naming-run", "status": failed ? "failed" : (request.httpMethod == "POST" ? "running" : "completed"), "prompt": "Name this conversation", "createdAt": "2030-01-01T12:00:00Z", "response": #"{"title":"Fix garden irrigation"}"#, "error": failed ? "Example provider unavailable" : ""]
            } else if request.httpMethod == "PATCH" {
                title = body["label"] as? String ?? title
            } else if path == "/api/v1/workspaces" {
                json["alerts"] = []
                json["workspaces"] = [["workspace_id": "w1", "label": "Garden", "panes": [["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "pi", "title": title, "pi_semantic": ["available": true, "protocolVersion": 1, "sessionId": "original-session"]]]]]
            }
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
    }
}
